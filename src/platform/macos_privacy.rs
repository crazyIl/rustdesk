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

enum CaptureState {
    Waiting,
    Frame(QuartzFrame),
    Stopped(String),
}

type SharedCaptureState = Arc<Mutex<CaptureState>>;

extern "C" {
    fn MacPrivacyCapturerCreate(
        display: u32,
        width: usize,
        height: usize,
        frame_handler: extern "C" fn(IOSurfaceRef, *mut c_void),
        error_handler: extern "C" fn(*const c_char, *mut c_void),
        context: *mut c_void,
        error_buffer: *mut c_char,
        error_buffer_size: usize,
    ) -> *mut c_void;
    fn MacPrivacyCapturerDestroy(capturer: *mut c_void);
}

pub struct PrivacyCapturer {
    handle: *mut c_void,
    _callback_context: Box<SharedCaptureState>,
    state: SharedCaptureState,
    saved_raw_data: Vec<u8>,
    width: usize,
    height: usize,
}

impl PrivacyCapturer {
    pub fn new(display: scrap::Display) -> io::Result<Self> {
        let width = display.width();
        let height = display.height();
        let state = Arc::new(Mutex::new(CaptureState::Waiting));
        let mut callback_context = Box::new(state.clone());
        let mut error_buffer = [0_i8; 512];
        let handle = unsafe {
            MacPrivacyCapturerCreate(
                display.id(),
                width,
                height,
                privacy_frame_callback,
                privacy_error_callback,
                callback_context.as_mut() as *mut SharedCaptureState as *mut c_void,
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
            state,
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
    let state = unsafe { &*(context as *const SharedCaptureState) };
    match state.lock() {
        Ok(mut state) => {
            if !matches!(&*state, CaptureState::Stopped(_)) {
                *state = CaptureState::Frame(unsafe { QuartzFrame::new(surface) });
            }
        }
        Err(_) => log::error!("Privacy capture frame lock is poisoned"),
    }
}

extern "C" fn privacy_error_callback(message: *const c_char, context: *mut c_void) {
    if context.is_null() {
        return;
    }
    let message = if message.is_null() {
        "Privacy capture stopped".to_owned()
    } else {
        unsafe { CStr::from_ptr(message) }
            .to_string_lossy()
            .into_owned()
    };
    let state = unsafe { &*(context as *const SharedCaptureState) };
    match state.lock() {
        Ok(mut state) => *state = CaptureState::Stopped(message),
        Err(_) => log::error!("Privacy capture state lock is poisoned"),
    }
}

impl TraitCapturer for PrivacyCapturer {
    fn frame<'a>(&'a mut self, _timeout: Duration) -> io::Result<Frame<'a>> {
        match self.state.try_lock() {
            Ok(mut state) => match mem::replace(&mut *state, CaptureState::Waiting) {
                CaptureState::Frame(mut frame) => {
                    scrap::would_block_if_equal(&mut self.saved_raw_data, frame.inner())?;
                    frame.surface_to_bgra(self.height);
                    Ok(Frame::PixelBuffer(PixelBuffer::new(
                        frame,
                        self.width,
                        self.height,
                    )))
                }
                CaptureState::Stopped(message) => {
                    *state = CaptureState::Stopped(message.clone());
                    Err(io::Error::new(io::ErrorKind::BrokenPipe, message))
                }
                CaptureState::Waiting => Err(io::ErrorKind::WouldBlock.into()),
            },
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
