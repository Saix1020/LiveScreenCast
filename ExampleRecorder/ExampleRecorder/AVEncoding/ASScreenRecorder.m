//
//  ASScreenRecorder.m
//  ScreenRecorder
//
//  Created by Alan Skipp on 23/04/2014.
//  Copyright (c) 2014 Alan Skipp. All rights reserved.
//

#import "ASScreenRecorder.h"
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import <AssetsLibrary/AssetsLibrary.h>
#import <sys/stat.h>
#import "AVEncoder.h"
#import "RTSPServer.h"


@interface ASScreenRecorder()
@property (strong, nonatomic) AVAssetWriter *videoWriter;
@property (strong, nonatomic) AVAssetWriterInput *videoWriterInput;
@property (strong, nonatomic) AVAssetWriterInputPixelBufferAdaptor *avAdaptor;
@property (strong, nonatomic) CADisplayLink *displayLink;
@property (strong, nonatomic) NSDictionary *outputBufferPoolAuxAttributes;
@property (nonatomic) CFTimeInterval firstTimeStamp;
@property (nonatomic) BOOL isRecording;
@property (nonatomic) CGSize viewSize;
@property (nonatomic, strong) dispatch_semaphore_t frameRenderingSemaphore;
@property (nonatomic, strong) dispatch_semaphore_t pixelAppendSemaphore;
@property (nonatomic, strong) RTSPServer* rtsp;
@property (nonatomic, strong) AVEncoder* encoder;
@property (nonatomic, strong) dispatch_queue_t append_pixelBuffer_queue;
@property (nonatomic) BOOL isSampleRecording;
@property (nonatomic, strong) NSString* sampleFilePath;

@property (nonatomic, strong) NSThread* backgroundThread;
@property (nonatomic, strong) NSRunLoop* backgroundRunLoop;

@end

@implementation ASScreenRecorder
{
    dispatch_queue_t _render_queue;
//    dispatch_queue_t _append_pixelBuffer_queue;
//    dispatch_semaphore_t _frameRenderingSemaphore;
//    dispatch_semaphore_t _pixelAppendSemaphore;
    
//    CGSize _viewSize;
    CGFloat _scale;
    
    CGColorSpaceRef _rgbColorSpace;
    CVPixelBufferPoolRef _outputBufferPool;
    
    NSInteger _count;
    
    // sample video file
//    NSString* _sampleFilePath;
//    BOOL _isSampleRecording;
    
//    AVEncoder* _encoder;
//    RTSPServer* _rtsp;
}

@synthesize viewSize = _viewSize;

#pragma mark - initializers

+ (instancetype)sharedInstance {
    static dispatch_once_t once;
    static ASScreenRecorder *sharedInstance;
    dispatch_once(&once, ^{
        sharedInstance = [[self alloc] init];
    });
    return sharedInstance;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _viewSize = [UIApplication sharedApplication].delegate.window.bounds.size;
        _scale = [UIScreen mainScreen].scale;
        // record half size resolution for retina iPads
        if ((UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) && _scale > 1) {
            _scale = 1.0;
        }
        _isRecording = NO;
        
        _append_pixelBuffer_queue = dispatch_queue_create("ASScreenRecorder.append_queue", DISPATCH_QUEUE_SERIAL);
        _render_queue = dispatch_queue_create("ASScreenRecorder.render_queue", DISPATCH_QUEUE_SERIAL);
        dispatch_set_target_queue(_render_queue, dispatch_get_global_queue( DISPATCH_QUEUE_PRIORITY_HIGH, 0));
        _frameRenderingSemaphore = dispatch_semaphore_create(1);
        _pixelAppendSemaphore = dispatch_semaphore_create(1);
        
        _isSampleRecording = NO;
        
        _backgroundThread = [[NSThread alloc] initWithTarget:self selector:@selector(backgroundThreadInit) object:nil];
        [_backgroundThread start];
    }
    return self;
}

-(void)backgroundThreadInit
{
    self.backgroundRunLoop = [NSRunLoop currentRunLoop];
    [self.backgroundRunLoop addPort:[NSMachPort port] forMode:NSDefaultRunLoopMode];
    while(1){
        @autoreleasepool {
            
            [self.backgroundRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]];
        }
    }
}
                             
#pragma mark - public

- (void)setVideoURL:(NSURL *)videoURL
{
    NSAssert(!_isRecording, @"videoURL can not be changed whilst recording is in progress");
    _videoURL = videoURL;
}

-(BOOL)startSampleRecodrding
{
    if (!_isSampleRecording) {
        [self setUpSampleWrite];
        _isSampleRecording = (_videoWriter.status == AVAssetWriterStatusWriting);

        _displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(writeVideoFrame)];
        [self performSelector:@selector(setDisplayLinkToBabkground) withObject:nil];
    }
    
    return _isSampleRecording;
}

-(void)setDisplayLinkToBabkground
{
    [_displayLink addToRunLoop:self.backgroundRunLoop forMode:NSRunLoopCommonModes];

}

-(void)setUpSampleWrite
{
    _rgbColorSpace = CGColorSpaceCreateDeviceRGB();
    
    NSDictionary *bufferAttributes = @{(id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
                                       (id)kCVPixelBufferCGBitmapContextCompatibilityKey : @YES,
                                       (id)kCVPixelBufferWidthKey : @(_viewSize.width * _scale),
                                       (id)kCVPixelBufferHeightKey : @(_viewSize.height * _scale),
                                       (id)kCVPixelBufferBytesPerRowAlignmentKey : @(_viewSize.width * _scale)
                                       };
    
    _outputBufferPool = NULL;
    CVPixelBufferPoolCreate(NULL, NULL, (__bridge CFDictionaryRef)(bufferAttributes), &_outputBufferPool);
    
    NSError* error = nil;
    _videoWriter = [[AVAssetWriter alloc] initWithURL:[self sampleFileURL]
                                             fileType:AVFileTypeQuickTimeMovie
                                                error:&error];
    NSParameterAssert(_videoWriter);
    
    NSInteger pixelNumber = _viewSize.width * _viewSize.height * _scale;
    NSDictionary* videoCompression = @{AVVideoAverageBitRateKey: @(pixelNumber * 11.4)};
    
    NSDictionary* videoSettings = @{AVVideoCodecKey: AVVideoCodecH264,
                                    AVVideoWidthKey: [NSNumber numberWithInt:_viewSize.width*_scale],
                                    AVVideoHeightKey: [NSNumber numberWithInt:_viewSize.height*_scale],
                                    AVVideoCompressionPropertiesKey: videoCompression};
    
    _videoWriterInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:videoSettings];
    NSParameterAssert(_videoWriterInput);
    
    _videoWriterInput.expectsMediaDataInRealTime = YES;
    _videoWriterInput.transform = [self videoTransformForDeviceOrientation];
    [_videoWriter addInput:_videoWriterInput];
    _avAdaptor = [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:_videoWriterInput sourcePixelBufferAttributes:nil];
    
    
    [_videoWriter startWriting];
    [_videoWriter startSessionAtSourceTime:CMTimeMake(0, 100)];
}

- (BOOL)startRecording
{
    if (!_isRecording) {
        [self setUpWriter];
        _isRecording = (_videoWriter.status == AVAssetWriterStatusWriting);
        _displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(writeVideoFrame)];
        [_displayLink addToRunLoop:self.backgroundRunLoop forMode:NSRunLoopCommonModes];
    }
    return _isRecording;
}

- (void)stopRecordingWithCompletion:(VideoCompletionBlock)completionBlock;
{
    if (_isRecording) {
        _isRecording = NO;
        [_displayLink removeFromRunLoop:self.backgroundRunLoop forMode:NSRunLoopCommonModes];
        [self completeRecordingSession:completionBlock];
    }
}

- (void)stopSampleRecordingWithCompletion:(VideoCompletionBlock)completionBlock;
{
    if (_isSampleRecording) {
        _isSampleRecording = NO;
        [_displayLink removeFromRunLoop:self.backgroundRunLoop forMode:NSRunLoopCommonModes];
        [self completeRecordingSampleSession:completionBlock];
    }
}


#pragma mark - private

-(void)setUpWriter
{
    _rgbColorSpace = CGColorSpaceCreateDeviceRGB();
    
    NSDictionary *bufferAttributes = @{(id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
                                       (id)kCVPixelBufferCGBitmapContextCompatibilityKey : @YES,
                                       (id)kCVPixelBufferWidthKey : @(_viewSize.width * _scale),
                                       (id)kCVPixelBufferHeightKey : @(_viewSize.height * _scale),
                                       (id)kCVPixelBufferBytesPerRowAlignmentKey : @(_viewSize.width * _scale)
                                       };
    
    _outputBufferPool = NULL;
    CVPixelBufferPoolCreate(NULL, NULL, (__bridge CFDictionaryRef)(bufferAttributes), &_outputBufferPool);


    _encoder = [AVEncoder encoderForHeight:[UIScreen mainScreen].bounds.size.width andWidth:[UIScreen mainScreen].bounds.size.height];
//    [_encoder setWriter:videoEncoder];
    VideoEncoder* writer = [_encoder writer];
        _videoWriter = writer->_writer;
        _videoWriterInput = writer->_writerInput;

    __weak typeof(self) weakSelf = self;
    [_encoder encodeWithBlock:^int(NSArray* data, double pts) {
        typeof(self) strongSelf = weakSelf;
        if (strongSelf.rtsp != nil)
        {
            strongSelf.rtsp.bitrate = strongSelf.encoder.bitspersecond;
            [strongSelf.rtsp onVideoData:data time:pts];
        }
        return 0;
    } onParams:^int(NSData *data) {
        typeof(self) strongSelf = weakSelf;

        strongSelf.rtsp = [RTSPServer setupListener:data];
        NSString* ipaddr = [RTSPServer getIPAddress];
        NSString* url = [NSString stringWithFormat:@"rtsp://%@:%hd/", ipaddr, strongSelf.rtsp.port];
        NSLog(@"url: %@", url);
        return 0;
    }];
    
    _avAdaptor = [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:_videoWriterInput sourcePixelBufferAttributes:nil];

    
    [_videoWriter startWriting];
    [_videoWriter startSessionAtSourceTime:CMTimeMake(0, 100)];
    [_encoder onParamsCompletionWithSampleFile:[self sampleFilePath]];
    
}

- (CGAffineTransform)videoTransformForDeviceOrientation
{
    CGAffineTransform videoTransform;
    switch ([UIDevice currentDevice].orientation) {
        case UIDeviceOrientationLandscapeLeft:
            videoTransform = CGAffineTransformMakeRotation(-M_PI_2);
            break;
        case UIDeviceOrientationLandscapeRight:
            videoTransform = CGAffineTransformMakeRotation(M_PI_2);
            break;
        case UIDeviceOrientationPortraitUpsideDown:
            videoTransform = CGAffineTransformMakeRotation(M_PI);
            break;
        default:
            videoTransform = CGAffineTransformIdentity;
    }
    return videoTransform;
}

- (NSURL*)tempFileURL
{
    NSString *outputPath = [NSHomeDirectory() stringByAppendingPathComponent:@"tmp/screenCapture.mp4"];
    [self removeTempFilePath:outputPath];
    return [NSURL fileURLWithPath:outputPath];
}

-(NSString*)sampleFilePath
{
    return [NSHomeDirectory() stringByAppendingPathComponent:@"tmp/sample.mp4"];
}
- (NSURL*)sampleFileURL
{
    NSString *outputPath = [self sampleFilePath];
    [self removeTempFilePath:outputPath];
    return [NSURL fileURLWithPath:outputPath];
}

- (void)removeTempFilePath:(NSString*)filePath
{
    NSFileManager* fileManager = [NSFileManager defaultManager];
    if ([fileManager fileExistsAtPath:filePath]) {
        NSError* error;
        if ([fileManager removeItemAtPath:filePath error:&error] == NO) {
            NSLog(@"Could not delete old recording:%@", [error localizedDescription]);
        }
    }
}

- (void)completeRecordingSampleSession:(VideoCompletionBlock)completionBlock
{
    __weak typeof(self) weakSelf = self;

    dispatch_async(_render_queue, ^{
        typeof(self) strongSelf = weakSelf;

        dispatch_sync(strongSelf.append_pixelBuffer_queue, ^{
            
            [strongSelf.videoWriterInput markAsFinished];
            [strongSelf.videoWriter finishWritingWithCompletionHandler:^{
                
                void (^completion)(void) = ^() {
                    [self cleanup];
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (completionBlock) completionBlock();
                    });
                };
                completion();

            }];
        });
    });
}

- (void)completeRecordingSession:(VideoCompletionBlock)completionBlock
{
    __weak typeof(self) weakSelf = self;

    dispatch_async(_render_queue, ^{
        typeof(self) strongSelf = weakSelf;
        dispatch_sync(strongSelf.append_pixelBuffer_queue, ^{
            
            [strongSelf.videoWriterInput markAsFinished];
            [strongSelf.videoWriter finishWritingWithCompletionHandler:^{
                
                void (^completion)(void) = ^() {
                    [self cleanup];
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (completionBlock) completionBlock();
                    });
                };
                
                if (self.videoURL) {
                    completion();
                } else {
                    ALAssetsLibrary *library = [[ALAssetsLibrary alloc] init];
                    [library writeVideoAtPathToSavedPhotosAlbum:strongSelf.videoWriter.outputURL completionBlock:^(NSURL *assetURL, NSError *error) {
                        if (error) {
                            NSLog(@"Error copying video to camera roll:%@", [error localizedDescription]);
                        } else {
                            [self removeTempFilePath:strongSelf.videoWriter.outputURL.path];
                            completion();
                        }
                    }];
                }
            }];
        });
    });
}



- (void)cleanup
{
    self.avAdaptor = nil;
    self.videoWriterInput = nil;
    self.videoWriter = nil;
    self.firstTimeStamp = 0;
    self.outputBufferPoolAuxAttributes = nil;
    CGColorSpaceRelease(_rgbColorSpace);
    CVPixelBufferPoolRelease(_outputBufferPool);
    
    if (_encoder) {
        [_encoder setWriter:nil];
        [_encoder shutdown];
        [_rtsp shutdownServer];
    }

}

- (void)writeVideoFrame
{
//    CFTimeInterval elapsed = (self.displayLink.timestamp -  self.firstTimeStamp);
//    if (elapsed < 100){
//        usleep(ceil(100-elapsed)*1000);
//        self.firstTimeStamp = self.displayLink.timestamp;
//        return;
//    }
    _count ++;
    if (_count%4 !=1) {
        return;
    }
    
    // throttle the number of frames to prevent meltdown
    // technique gleaned from Brad Larson's answer here: http://stackoverflow.com/a/5956119
    if (dispatch_semaphore_wait(_frameRenderingSemaphore, DISPATCH_TIME_NOW) != 0) {
        return;
    }
    __weak typeof(self) weakSelf = self;
    dispatch_async(_render_queue, ^{
        typeof(self) strongSelf = weakSelf;
        if (![strongSelf.videoWriterInput isReadyForMoreMediaData])
        {
            dispatch_semaphore_signal(strongSelf.frameRenderingSemaphore);
            return;
        }
        
        if (!self.firstTimeStamp) {
            self.firstTimeStamp = strongSelf.displayLink.timestamp;
        }
        CFTimeInterval elapsed = (strongSelf.displayLink.timestamp - strongSelf.firstTimeStamp);
        CMTime time = CMTimeMakeWithSeconds(elapsed, 100);
        
        CVPixelBufferRef pixelBuffer = NULL;
        CGContextRef bitmapContext = [strongSelf createPixelBufferAndBitmapContext:&pixelBuffer];
        
        if (strongSelf.delegate) {
            [strongSelf.delegate writeBackgroundFrameInContext:&bitmapContext];
        }
        // draw each window into the context (other windows include UIKeyboard, UIAlert)
        // FIX: UIKeyboard is currently only rendered correctly in portrait orientation
        dispatch_sync(dispatch_get_main_queue(), ^{
            UIGraphicsPushContext(bitmapContext); {
                for (UIWindow *window in [[UIApplication sharedApplication] windows]) {
                    [window drawViewHierarchyInRect:CGRectMake(0, 0, strongSelf.viewSize.width, strongSelf.viewSize.height) afterScreenUpdates:NO];
                }
            } UIGraphicsPopContext();
        });
        
        // append pixelBuffer on a async dispatch_queue, the next frame is rendered whilst this one appends
        // must not overwhelm the queue with pixelBuffers, therefore:
        // check if _append_pixelBuffer_queue is ready
        // if it’s not ready, release pixelBuffer and bitmapContext
        if (dispatch_semaphore_wait(strongSelf.pixelAppendSemaphore, DISPATCH_TIME_NOW) == 0) {
            dispatch_async(strongSelf.append_pixelBuffer_queue, ^{
                BOOL success = [strongSelf.avAdaptor appendPixelBuffer:pixelBuffer withPresentationTime:time];
                if (!success) {
                    NSLog(@"Warning: Unable to write buffer to video");
                }
                CGContextRelease(bitmapContext);
                CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
                CVPixelBufferRelease(pixelBuffer);
                
                dispatch_semaphore_signal(strongSelf.pixelAppendSemaphore);
                if (strongSelf.isSampleRecording) {
                    NSFileHandle* file = [NSFileHandle fileHandleForReadingAtPath:[NSHomeDirectory() stringByAppendingPathComponent:@"tmp/sample.mp4"]];
                    struct stat s;
                    fstat([file fileDescriptor], &s);
                    if (s.st_size>0) {
                        [self stopSampleRecordingWithCompletion:^(){
                            [self startRecording];
                        }];
                    }
                }
                else {
                    [strongSelf.encoder addTimer:@(elapsed)];
                }
                
                
            });
        } else {
            CGContextRelease(bitmapContext);
            CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
            CVPixelBufferRelease(pixelBuffer);
        }
        
        dispatch_semaphore_signal(strongSelf.frameRenderingSemaphore);
    });
}

- (CGContextRef)createPixelBufferAndBitmapContext:(CVPixelBufferRef *)pixelBuffer
{
    CVPixelBufferPoolCreatePixelBuffer(NULL, _outputBufferPool, pixelBuffer);
    CVPixelBufferLockBaseAddress(*pixelBuffer, 0);
    
    CGContextRef bitmapContext = NULL;
    bitmapContext = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(*pixelBuffer),
                                          CVPixelBufferGetWidth(*pixelBuffer),
                                          CVPixelBufferGetHeight(*pixelBuffer),
                                          8, CVPixelBufferGetBytesPerRow(*pixelBuffer), _rgbColorSpace,
                                          kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst
                                          );
    CGContextScaleCTM(bitmapContext, _scale, _scale);
    CGAffineTransform flipVertical = CGAffineTransformMake(1, 0, 0, -1, 0, _viewSize.height);
    CGContextConcatCTM(bitmapContext, flipVertical);
    
    return bitmapContext;
}

@end
