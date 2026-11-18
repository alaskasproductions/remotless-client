// Remotless: iPhone/iPad screen sharing (view only).
//
// iOS lets only a ReplayKit Broadcast Upload Extension see the screen. The extension
// (flutter/ios/RemotlessBroadcast) scales each frame down, converts it to BGRA and hands it to
// `push_frame`, which keeps the newest frame. The video service reads it through `Capturer`,
// the same way the Android capturer reads the frames MediaProjection pushes over JNI.
// See docs/ios-screen-share.md.

use crate::{Frame, Pixfmt};
use std::{
    io,
    sync::{Condvar, Mutex},
    time::Duration,
};

struct Latest {
    data: Vec<u8>,
    width: usize,
    height: usize,
    stride: usize,
    fresh: bool,
}

lazy_static::lazy_static! {
    static ref LATEST: Mutex<Latest> = Mutex::new(Latest {
        data: Vec::new(),
        width: 0,
        height: 0,
        stride: 0,
        fresh: false,
    });
    static ref NEW_FRAME: Condvar = Condvar::new();
}

/// Called by the broadcast extension for every frame it keeps: BGRA, `stride` bytes per row.
/// Copies into a buffer that is reused, so memory stays flat (the extension has ~50 MB).
pub fn push_frame(data: &[u8], width: usize, height: usize, stride: usize) {
    if width == 0 || height == 0 || stride < width * 4 || data.len() < stride * height {
        return;
    }
    let mut l = LATEST.lock().unwrap();
    let n = stride * height;
    if l.data.len() != n {
        l.data = vec![0u8; n];
    }
    l.data.copy_from_slice(&data[..n]);
    l.width = width;
    l.height = height;
    l.stride = stride;
    l.fresh = true;
    drop(l);
    NEW_FRAME.notify_all();
}

/// Forgets the last frame (the broadcast stopped).
pub fn clear() {
    let mut l = LATEST.lock().unwrap();
    l.data = Vec::new();
    l.width = 0;
    l.height = 0;
    l.stride = 0;
    l.fresh = false;
}

/// Size of the frames the extension sends (0x0 until the first one).
pub fn screen_size() -> (usize, usize) {
    let l = LATEST.lock().unwrap();
    (l.width, l.height)
}

/// Waits up to `timeout` for the first frame, so the display size is known when a
/// technician connects right after the broadcast starts.
pub fn wait_first_frame(timeout: Duration) -> bool {
    let l = LATEST.lock().unwrap();
    if l.width > 0 {
        return true;
    }
    let (l, _) = NEW_FRAME
        .wait_timeout_while(l, timeout, |l| l.width == 0)
        .unwrap();
    l.width > 0
}

pub struct Capturer {
    display: Display,
    bgra: Vec<u8>,
    stride: usize,
}

impl Capturer {
    pub fn new(display: Display) -> io::Result<Capturer> {
        Ok(Capturer {
            display,
            bgra: Vec::new(),
            stride: 0,
        })
    }

    pub fn width(&self) -> usize {
        self.display.width()
    }

    pub fn height(&self) -> usize {
        self.display.height()
    }
}

impl crate::TraitCapturer for Capturer {
    fn frame<'a>(&'a mut self, timeout: Duration) -> io::Result<Frame<'a>> {
        let l = LATEST.lock().unwrap();
        let (mut l, _) = NEW_FRAME
            .wait_timeout_while(l, timeout, |l| !l.fresh)
            .unwrap();
        if !l.fresh {
            return Err(io::ErrorKind::WouldBlock.into());
        }
        // The phone was rotated: the video service sees the new size and restarts the capturer.
        if l.width != self.display.width() || l.height != self.display.height() {
            return Err(io::Error::new(
                io::ErrorKind::Other,
                "screen size changed (rotation)",
            ));
        }
        l.fresh = false;
        if self.bgra.len() != l.data.len() {
            self.bgra = vec![0u8; l.data.len()];
        }
        self.bgra.copy_from_slice(&l.data);
        self.stride = l.stride;
        drop(l);
        Ok(Frame::PixelBuffer(PixelBuffer {
            data: &self.bgra,
            width: self.display.width(),
            height: self.display.height(),
            stride: vec![self.stride],
        }))
    }
}

pub struct PixelBuffer<'a> {
    data: &'a [u8],
    width: usize,
    height: usize,
    stride: Vec<usize>,
}

impl<'a> PixelBuffer<'a> {
    pub fn new(data: &'a [u8], width: usize, height: usize) -> Self {
        let stride = if height > 0 { data.len() / height } else { 0 };
        PixelBuffer {
            data,
            width,
            height,
            stride: vec![stride],
        }
    }
}

impl<'a> crate::TraitPixelBuffer for PixelBuffer<'a> {
    fn data(&self) -> &[u8] {
        self.data
    }

    fn width(&self) -> usize {
        self.width
    }

    fn height(&self) -> usize {
        self.height
    }

    fn stride(&self) -> Vec<usize> {
        self.stride.clone()
    }

    fn pixfmt(&self) -> Pixfmt {
        Pixfmt::BGRA
    }
}

pub struct Display {
    width: usize,
    height: usize,
}

impl Display {
    pub fn primary() -> io::Result<Display> {
        // A technician can connect the moment the broadcast starts, before the first frame.
        wait_first_frame(Duration::from_secs(3));
        let (width, height) = screen_size();
        Ok(Display { width, height })
    }

    pub fn all() -> io::Result<Vec<Display>> {
        Ok(vec![Display::primary()?])
    }

    pub fn width(&self) -> usize {
        self.width
    }

    pub fn height(&self) -> usize {
        self.height
    }

    pub fn origin(&self) -> (i32, i32) {
        (0, 0)
    }

    pub fn is_online(&self) -> bool {
        true
    }

    pub fn is_primary(&self) -> bool {
        true
    }

    pub fn name(&self) -> String {
        "iPhone".into()
    }
}
