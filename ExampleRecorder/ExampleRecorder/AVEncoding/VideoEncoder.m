//
//  VideoEncoder.m
//  Encoder Demo
//
//  Created by Geraint Davies on 14/01/2013.
//  Copyright (c) 2013 GDCL http://www.gdcl.co.uk/license.htm
//

#import "VideoEncoder.h"

@implementation VideoEncoder

@synthesize path = _path;

+ (VideoEncoder*) encoderForPath:(NSString*) path Height:(int) height andWidth:(int) width
{
    VideoEncoder* enc = [VideoEncoder alloc];
    [enc initPath:path Height:height andWidth:width];
    return enc;
}


- (void) initPath:(NSString*)path Height:(int) height andWidth:(int) width
{
    self.path = path;
    
    short scale = [UIScreen mainScreen].scale;
    CGSize viewSize = [UIApplication sharedApplication].delegate.window.bounds.size;

    
    [[NSFileManager defaultManager] removeItemAtPath:self.path error:nil];
    NSURL* url = [NSURL fileURLWithPath:self.path];
    
    _writer = [AVAssetWriter assetWriterWithURL:url fileType:AVFileTypeQuickTimeMovie error:nil];
    
    NSInteger pixelNumber = viewSize.width * viewSize.height * scale;
    NSDictionary* videoCompression = @{AVVideoAverageBitRateKey: @(pixelNumber * 11.4)};
    
    NSDictionary* settings = @{AVVideoCodecKey: AVVideoCodecH264,
                                    AVVideoWidthKey: [NSNumber numberWithInt:viewSize.width*scale],
                                    AVVideoHeightKey: [NSNumber numberWithInt:viewSize.height*scale],
                                    AVVideoCompressionPropertiesKey: videoCompression};

    
//    NSDictionary* settings = [NSDictionary dictionaryWithObjectsAndKeys:
//                              AVVideoCodecH264, AVVideoCodecKey,
//                              [NSNumber numberWithInt: width], AVVideoWidthKey,
//                              [NSNumber numberWithInt:height], AVVideoHeightKey,
//                              [NSDictionary dictionaryWithObjectsAndKeys:
//                                    @YES, AVVideoAllowFrameReorderingKey, nil],
//                                    AVVideoCompressionPropertiesKey,
//                              nil];
    _writerInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:settings];
    _writerInput.expectsMediaDataInRealTime = YES;
    
    
    
    _writerInput.expectsMediaDataInRealTime = YES;
    _writerInput.transform = [self videoTransformForDeviceOrientation];
    
    [_writer addInput:_writerInput];
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

- (void) finishWithCompletionHandler:(void (^)(void))handler
{
    [_writer finishWritingWithCompletionHandler: handler];
}

- (BOOL) encodeFrame:(CMSampleBufferRef) sampleBuffer
{
    if (CMSampleBufferDataIsReady(sampleBuffer))
    {
        if (_writer.status == AVAssetWriterStatusUnknown)
        {
            CMTime startTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
            [_writer startWriting];
            [_writer startSessionAtSourceTime:startTime];
        }
        if (_writer.status == AVAssetWriterStatusFailed)
        {
            NSLog(@"writer error %@", _writer.error.localizedDescription);
            return NO;
        }
        if (_writerInput.readyForMoreMediaData == YES)
        {
            [_writerInput appendSampleBuffer:sampleBuffer];
            return YES;
        }
    }
    return NO;
}

@end
