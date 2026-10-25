#import "ROBAccumulatedSurfaceRenderer.h"
#import <CoreImage/CoreImage.h>
#import <Vision/Vision.h>
#include <assert.h>
#include <stdio.h>

static bool decodes(CGImageRef image) {
    VNDetectBarcodesRequest *request=[VNDetectBarcodesRequest new];request.symbologies=@[VNBarcodeSymbologyQR];
    VNImageRequestHandler *handler=[[VNImageRequestHandler alloc] initWithCGImage:image options:@{}];
    assert([handler performRequests:@[request] error:NULL]);
    for (VNBarcodeObservation *code in request.results) if ([code.payloadStringValue isEqual:@"ROB:STABLE:SURFACE"]) return true;
    return false;
}
static uint64_t hashImage(CGImageRef image) {
    CFDataRef data=CGDataProviderCopyData(CGImageGetDataProvider(image));const uint8_t *bytes=CFDataGetBytePtr(data);
    uint64_t hash=1469598103934665603ull;for (CFIndex i=0;i<CFDataGetLength(data);i++) {hash^=bytes[i];hash*=1099511628211ull;}CFRelease(data);return hash;
}
int main(int argc,const char *argv[]) { @autoreleasepool {
    enum {width=320,height=320};
    CVPixelBufferRef rgb=NULL;assert(CVPixelBufferCreate(NULL,width,height,kCVPixelFormatType_32BGRA,NULL,&rgb)==kCVReturnSuccess);
    CIFilter *filter=[CIFilter filterWithName:@"CIQRCodeGenerator"];
    [filter setValue:[@"ROB:STABLE:SURFACE" dataUsingEncoding:NSUTF8StringEncoding] forKey:@"inputMessage"];
    [filter setValue:@"H" forKey:@"inputCorrectionLevel"];
    CIImage *code=[filter.outputImage imageByApplyingTransform:CGAffineTransformMakeScale(6,6)];
    code=[code imageByApplyingTransform:CGAffineTransformMakeTranslation((width-code.extent.size.width)/2,(height-code.extent.size.height)/2)];
    CIContext *context=[CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer:@YES}];
    uint8_t depth[width*height*2];for (int i=0;i<width*height;i++) {depth[i*2]=0xE8;depth[i*2+1]=3;}
    ROBSurfaceDepthView view={width,height,depth,240,240,159.5,159.5,{1,0,0,0,0,-1,0,0,0,0,-1,0}};
    ROBSurfaceAccumulator *accumulator=[ROBSurfaceAccumulator new];uint64_t expectedHash=0;uint32_t expectedID=0;size_t decoded=0;
    for (int frame=1;frame<=12;frame++) { @autoreleasepool {
        CGFloat white=1-(frame-1)*.012;
        CIImage *background=[[CIImage imageWithColor:[CIColor colorWithRed:white green:white blue:white]] imageByCroppingToRect:CGRectMake(0,0,width,height)];
        CIImage *image=[code imageByCompositingOverImage:background];
        [context render:image toCVPixelBuffer:rgb bounds:CGRectMake(0,0,width,height) colorSpace:NULL];
        NSMutableData *samples=[NSMutableData data];
        CVPixelBufferLockBaseAddress(rgb,kCVPixelBufferLock_ReadOnly);const uint8_t *pixels=CVPixelBufferGetBaseAddress(rgb);size_t stride=CVPixelBufferGetBytesPerRow(rgb);
        for (int y=0;y<height;y+=4) for (int x=0;x<width;x+=4) {
            const uint8_t *p=pixels+(size_t)y*stride+x*4;
            ROBSurfaceSample sample={{(x-159.5)/240.,-(y-159.5)/240.,-1},((uint32_t)p[2]<<24)|((uint32_t)p[1]<<16)|((uint32_t)p[0]<<8)|255u};
            [samples appendBytes:&sample length:sizeof(sample)];
        }
        CVPixelBufferUnlockBaseAddress(rgb,kCVPixelBufferLock_ReadOnly);NSString *summary=nil;
        SCNNode *node=[accumulator accumulate:samples view:view capturedAt:frame*.25 sequence:frame rgbPixelBuffer:rgb summary:&summary];assert(node);
        if (frame<2) continue;
        ROBSurfaceTrackedNode *plane=nil;for (SCNNode *child in node.childNodes) if ([child isKindOfClass:ROBSurfaceTrackedNode.class] && ((ROBSurfaceTrackedNode *)child).surfaceTrackID) {plane=(ROBSurfaceTrackedNode *)child;break;}
        assert(plane);CGImageRef atlas=(__bridge CGImageRef)plane.geometry.firstMaterial.diffuse.contents;
        assert(CGImageGetWidth(atlas)>500 && CGImageGetHeight(atlas)>500 && decodes(atlas));decoded++;
        uint64_t hash=hashImage(atlas);
        if (!expectedHash) {expectedHash=hash;expectedID=plane.surfaceTrackID;}
        assert(hash==expectedHash && plane.surfaceTrackID==expectedID);
        if (frame==12 && argc>1) {
            NSBitmapImageRep *bitmap=[[NSBitmapImageRep alloc] initWithCGImage:atlas];
            assert([[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:@(argv[1]) atomically:YES]);
        }
    } }
    CVPixelBufferRelease(rgb);
    printf("Photographic surface passed: %zu consecutive QR decodes, same plane identity, bit-identical photographic texture despite changing input exposure; no camera/actuator IO.\n",decoded);
} }
