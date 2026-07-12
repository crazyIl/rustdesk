use hbb_common::log;
use scrap::{
    quartz::{ffi::IOSurfaceRef, Frame as QuartzFrame},
    Frame, PixelBuffer, TraitCapturer,
};
use std::{
    ffi::{c_char, c_void, CStr},
    io, mem,
    sync::{Arc, Mutex, TryLockError},
    time::Duration,
};

type FrameSlot = Arc<Mutex<Option<QuartzFrame>>>;

extern "C" {
    fn MacPrivacyCapturerCreate(
        display: u32,
        width: usize,
        height: usize,
        handler: extern "C" fn(IOSurfaceRef, *mut c_void),
        context: *mut c_void,
        error_buffer: *mut c_char,
        error_buffer_size: usize,
    ) -> *mut c_void;
    fn MacPrivacyCapturerDestroy(capturer: *mut c_void);
}

pub struct PrivacyCapturer {
    handle: *mut c_void,
    _callback_context: Box<FrameSlot>,
    frame: FrameSlot,
    saved_raw_data: Vec<u8>,
    width: usize,
    height: usize,
}

impl PrivacyCapturer {
    pub fn new(display: scrap::Display) -> io::Result<Self> {
        let width = display.width();
        let height = display.height();
        let frame = Arc::new(Mutex::new(None));
        let mut callback_context = Box::new(frame.clone());
        let mut error_buffer = [0_i8; 512];
        let handle = unsafe {
            MacPrivacyCapturerCreate(
                display.id(),
                width,
                height,
                privacy_frame_callback,
                callback_context.as_mut() as *mut FrameSlot as *mut c_void,
                error_buffer.as_mut_ptr(),
                error_buffer.len(),
            )
        };
        if handle.is_null() {
            let message = unsafe { CStr::from_ptr(error_buffer.as_ptr()) }
                .to_string_lossy()
                .into_owned();
            return Err(io::Error::new(
                io::ErrorKind::Other,
                if message.is_empty() {
                    "Failed to create privacy capturer".to_owned()
                } else {
                    message
                },
            ));
        }
        Ok(Self {
            handle,
            _callback_context: callback_context,
            frame,
            saved_raw_data: Vec::new(),
            width,
            height,
        })
    }
}

extern "C" fn privacy_frame_callback(surface: IOSurfaceRef, context: *mut c_void) {
    if surface.is_null() || context.is_null() {
        log::error!("Privacy capture returned an invalid frame");
        return;
    }
    let frame = unsafe { &*(context as *const FrameSlot) };
    match frame.lock() {
        Ok(mut slot) => *slot = Some(unsafe { QuartzFrame::new(surface) }),
        Err(_) => log::error!("Privacy capture frame lock is poisoned"),
    }
}

impl TraitCapturer for PrivacyCapturer {
    fn frame<'a>(&'a mut self, _timeout: Duration) -> io::Result<Frame<'a>> {
        match self.frame.try_lock() {
            Ok(mut slot) => {
                let mut frame = None;
                mem::swap(&mut frame, &mut slot);
                match frame {
                    Some(mut frame) => {
                        scrap::would_block_if_equal(&mut self.saved_raw_data, frame.inner())?;
                        frame.surface_to_bgra(self.height);
                        Ok(Frame::PixelBuffer(PixelBuffer::new(
                            frame,
                            self.width,
                            self.height,
                        )))
                    }
                    None => Err(io::ErrorKind::WouldBlock.into()),
                }
            }
            Err(TryLockError::WouldBlock) => Err(io::ErrorKind::WouldBlock.into()),
            Err(TryLockError::Poisoned(_)) => Err(io::ErrorKind::Other.into()),
        }
    }
}

impl Drop for PrivacyCapturer {
    fn drop(&mut self) {
        unsafe { MacPrivacyCapturerDestroy(self.handle) };
        self.handle = std::ptr::null_mut();
    }
}
