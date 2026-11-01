// Compile the actual atlas implementation so metrics inspect locked texels,
// not a second implementation of the stitcher. No camera or robot services.
#import "../Cerebro/ROBAccumulatedSurfaceRenderer.m"
#import <CoreImage/CoreImage.h>
#import <Vision/Vision.h>
#include <assert.h>
#include <stdio.h>

static uint32_t locked(ROBSurfacePhotoAtlas *a,double u,double v) {
    int x=(int)floor((u-a->originU)/a->texelMeters),y=(int)floor((v-a->originV)/a->texelMeters);
    assert(x>=0 && x<a->width && y>=0 && y<a->height);
    return ((const uint32_t *)a->pixels.bytes)[(size_t)y*a->width+x];
}
static NSColor *displayed(ROBSurfacePhotoAtlas *a,double u,double v) {
    return [[a->bitmap colorAtX:(int)floor((u-a->originU)/a->texelMeters) y:(int)floor((v-a->originV)/a->texelMeters)]
        colorUsingColorSpace:NSColorSpace.deviceRGBColorSpace];
}
static CGPoint qrWorld(ROBSurfacePhotoAtlas *a) {
    VNDetectBarcodesRequest *r=[VNDetectBarcodesRequest new];r.symbologies=@[VNBarcodeSymbologyQR];
    VNImageRequestHandler *h=[[VNImageRequestHandler alloc] initWithCGImage:a.image options:@{}];
    assert([h performRequests:@[r] error:NULL]);
    for (VNBarcodeObservation *o in r.results) if ([o.payloadStringValue isEqual:@"ROB:MULTIVIEW:FIXED"])
        return CGPointMake(a->originU+CGRectGetMidX(o.boundingBox)*a->width*a->texelMeters,
                           a->originV+(1-CGRectGetMidY(o.boundingBox))*a->height*a->texelMeters);
    return CGPointMake(NAN,NAN);
}
int main(int argc,const char **argv) { @autoreleasepool {
    [NSApplication sharedApplication];
    CIFilter *qr=[CIFilter filterWithName:@"CIQRCodeGenerator"];
    [qr setValue:[@"ROB:MULTIVIEW:FIXED" dataUsingEncoding:NSUTF8StringEncoding] forKey:@"inputMessage"];
    [qr setValue:@"H" forKey:@"inputCorrectionLevel"];
    CIImage *code=[qr.outputImage imageByApplyingTransform:CGAffineTransformMakeScale(5,5)];
    CIContext *context=[CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer:@YES}];
    CGImageRef codeImage=[context createCGImage:code fromRect:code.extent];
    NSBitmapImageRep *pattern=[[NSBitmapImageRep alloc] initWithCGImage:codeImage];CGImageRelease(codeImage);
    const double qrU=-.29,qrV=.02,qrPixel=.002;
    enum {w=480,h=360};uint8_t depth[w*h*2];
    CVPixelBufferRef rgb=NULL;assert(CVPixelBufferCreate(NULL,w,h,kCVPixelFormatType_32BGRA,NULL,&rgb)==kCVReturnSuccess);
    ROBSurfacePhotoAtlas *atlas=[ROBSurfacePhotoAtlas new];
    uint32_t coarse[60*30];for (size_t i=0;i<60*30;i++) coarse[i]=0x18B030FF;
    ROBSurfacePlane plane={.normal={0,0,1},.u={1,0,0},.v={0,1,0},.offset=1,.originU=-20,.originV=-12,
        .width=25,.height=24,.rgba=coarse,.rms=.002,.trackID=1};
    uint32_t probe=0;CGPoint initial=CGPointZero;double maxError=0;NSUInteger firstCoverage=0,lastVisits=0;
    ROBSurfaceAccumulator *pipeline=[ROBSurfaceAccumulator new];uint32_t planeID=0;unsigned pipelineDecodes=0;
    double pipelineError=0;
    for (int frame=0;frame<8;frame++) {
        double theta=frame<2 ? 0 : (frame%2 ? -.16 : .16),tx=frame<2 ? -.25 : (frame%2 ? -.25 : .25);
        double c=cos(theta),s=sin(theta);
        ROBSurfaceDepthView view={w,h,depth,400,400,239.5,179.5,{c,0,s,tx,0,-1,0,0,s,0,-c,0}};
        if (frame==2) {plane.width=40;plane.originU=-20;}
        NSMutableData *samples=[NSMutableData data];
        CVPixelBufferLockBaseAddress(rgb,0);uint8_t *pixels=CVPixelBufferGetBaseAddress(rgb);size_t stride=CVPixelBufferGetBytesPerRow(rgb);
        for (int y=0;y<h;y++) for (int x=0;x<w;x++) {
            double rx=(x-view.cx)/view.fx,ry=(y-view.cy)/view.fy;
            double z=1/(c-s*rx),u=tx+z*(c*rx+s),v=-z*ry;
            BOOL occluded=frame<4 && u>.30 && u<.48 && fabs(v)<.2;
            unsigned mm=(unsigned)lround((occluded ? z-.20 : z+sin(x*.1+y*.2+frame)*.002)*1000);
            size_t index=((size_t)y*w+x)*2;depth[index]=mm&255;depth[index+1]=mm>>8;
            double value=.95-frame*.015;
            int qx=(int)floor((u-qrU)/qrPixel),qy=(int)floor((v-qrV)/qrPixel);
            if (qx>=0 && qx<pattern.pixelsWide && qy>=0 && qy<pattern.pixelsHigh)
                value=[[pattern colorAtX:qx y:qy] colorUsingColorSpace:NSColorSpace.deviceRGBColorSpace].redComponent;
            uint8_t *p=pixels+(size_t)y*stride+x*4;
            p[0]=occluded ? 10 : (uint8_t)lround(value*255);p[1]=p[0];p[2]=occluded ? 240 : p[0];p[3]=255;
            if (x%4==0 && y%4==0) {
                double measured=mm*.001;
                ROBSurfaceSample sample={{tx+measured*(c*rx+s),-measured*ry,measured*(s*rx-c)},
                    ((uint32_t)p[2]<<24)|((uint32_t)p[1]<<16)|((uint32_t)p[0]<<8)|255u};
                [samples appendBytes:&sample length:sizeof(sample)];
            }
        }
        CVPixelBufferUnlockBaseAddress(rgb,0);
        [atlas updatePlane:&plane view:view rgb:frame==2 ? NULL : rgb];
        NSString *summary=nil;
        SCNNode *root=[pipeline accumulate:samples view:view capturedAt:(frame+1)*.25 sequence:frame+1
            rgbPixelBuffer:frame==2 ? NULL : rgb summary:&summary];assert(root);
        if (frame>=1) {
            ROBSurfaceTrackedNode *surface=nil;
            for (SCNNode *child in root.childNodes) if ([child isKindOfClass:ROBSurfaceTrackedNode.class]) {
                ROBSurfaceTrackedNode *candidate=(ROBSurfaceTrackedNode *)child;
                if (candidate.surfaceTrackID && (!planeID || candidate.surfaceTrackID==planeID)) {surface=candidate;break;}
            }
            assert(surface);planeID=surface.surfaceTrackID;
            CGImageRef photo=(__bridge CGImageRef)surface.geometry.firstMaterial.diffuse.contents;
            VNDetectBarcodesRequest *request=[VNDetectBarcodesRequest new];request.symbologies=@[VNBarcodeSymbologyQR];
            VNImageRequestHandler *handler=[[VNImageRequestHandler alloc] initWithCGImage:photo options:@{}];
            assert([handler performRequests:@[request] error:NULL]);
            VNBarcodeObservation *found=nil;for(VNBarcodeObservation *value in request.results)
                if([value.payloadStringValue isEqual:@"ROB:MULTIVIEW:FIXED"]) found=value;
            assert(found);pipelineDecodes++;
            // Recover a world point from the ACTUAL rendered quad vertices/UVs,
            // independently of the atlas's private plane-frame bookkeeping.
            SCNGeometrySource *vertices=[surface.geometry geometrySourcesForSemantic:SCNGeometrySourceSemanticVertex].firstObject;
            SCNGeometrySource *uv=[surface.geometry geometrySourcesForSemantic:SCNGeometrySourceSemanticTexcoord].firstObject;
            const float *a=(const float *)((const uint8_t *)vertices.data.bytes+vertices.dataOffset);
            const float *b=(const float *)((const uint8_t *)vertices.data.bytes+vertices.dataOffset+vertices.dataStride);
            const float *d=(const float *)((const uint8_t *)vertices.data.bytes+vertices.dataOffset+vertices.dataStride*3);
            const float *ta=(const float *)((const uint8_t *)uv.data.bytes+uv.dataOffset);
            const float *tb=(const float *)((const uint8_t *)uv.data.bytes+uv.dataOffset+uv.dataStride);
            const float *td=(const float *)((const uint8_t *)uv.data.bytes+uv.dataOffset+uv.dataStride*3);
            double fu=(CGRectGetMidX(found.boundingBox)-ta[0])/(tb[0]-ta[0]);
            double fv=(1-CGRectGetMidY(found.boundingBox)-ta[1])/(td[1]-ta[1]);
            double world[3];for(int k=0;k<3;k++) world[k]=a[k]+(b[k]-a[k])*fu+(d[k]-a[k])*fv;
            double expectedU=qrU+pattern.pixelsWide*qrPixel/2,expectedV=qrV+pattern.pixelsHigh*qrPixel/2;
            double error=hypot(hypot(world[0]-expectedU,world[1]-expectedV),world[2]+1);
            pipelineError=fmax(pipelineError,error);assert(error<.005);
        }
        CGPoint center=qrWorld(atlas);assert(isfinite(center.x));
        if (!frame) {initial=center;probe=locked(atlas,-.151,.151);firstCoverage=atlas->filled;}
        double error=hypot(center.x-initial.x,center.y-initial.y);maxError=fmax(maxError,error);
        assert(error<.003 && locked(atlas,-.151,.151)==probe);
        if (frame==2) {
            assert(atlas->originU+atlas->width*atlas->texelMeters>=.8);
            assert(!locked(atlas,.39,.01));
            NSColor *color=displayed(atlas,.39,.01);assert(color.greenComponent>.6 && color.redComponent<.2);
            // Fallback changes must publish even without new RGB or extent.
            for (size_t i=0;i<60*30;i++) coarse[i]=0x1040C0FF;
            [atlas updatePlane:&plane view:view rgb:NULL];
            color=displayed(atlas,.39,.01);assert(color.blueComponent>.6 && color.redComponent<.2);
        }
        if (frame==3) assert(!locked(atlas,.39,.01)); // foreground never baked into table
        if (frame>=4) assert(locked(atlas,.39,.01)); // clear depth refills the hole
        if (frame==7) lastVisits=atlas->lastTexelVisits;
    }
    printf("VOXEL_STITCH_METRICS {\"post_warmup_views\":%u,\"stable_plane_id\":%u,\"max_qr_world_error_mm\":%.4f}\n",pipelineDecodes,planeID,pipelineError*1000);
    assert(pipelineDecodes==7);
    NSUInteger pixels=(NSUInteger)atlas->width*atlas->height;
    assert(atlas->filled>firstCoverage*1.3 && lastVisits<pixels*.35);
    double expectedU=qrU+pattern.pixelsWide*qrPixel/2,expectedV=qrV+pattern.pixelsHigh*qrPixel/2;
    assert(hypot(initial.x-expectedU,initial.y-expectedV)<.004);
    if (argc>1) assert([[atlas->bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:@(argv[1]) atomically:YES]);
    printf("STITCH_METRICS {\"views\":8,\"qr_decodes\":8,\"qr_world_drift_mm\":%.4f,\"initial_photo_texels\":%lu,\"final_photo_texels\":%lu,\"atlas_texels\":%lu,\"refill_texel_visits\":%lu,\"occluder_rejected\":true,\"missing_rgb_growth_and_recolor\":true}\n",
        maxError*1000,(unsigned long)firstCoverage,(unsigned long)atlas->filled,(unsigned long)pixels,(unsigned long)lastVisits);
    // Force bounded coarsening and a shifted origin. The retained world point
    // still samples its old 2mm cell; no UV translation accompanies resizing.
    plane.originU=-60;plane.width=120;plane.rgba=calloc((size_t)plane.width*plane.height,sizeof(uint32_t));
    for (int i=0;i<plane.width*plane.height;i++) plane.rgba[i]=0x18B030FF;
    ROBSurfaceDepthView empty={0};uint32_t retained=locked(atlas,-.15,.15);
    [atlas updatePlane:&plane view:empty rgb:NULL];
    assert(atlas->texelMeters==.004 && atlas->width<=2048 && locked(atlas,-.15,.15)==retained);
    CGPoint coarsened=qrWorld(atlas);assert(isfinite(coarsened.x) && hypot(coarsened.x-initial.x,coarsened.y-initial.y)<.006);
    printf("Coarsened atlas QR drift: %.4f mm; capped dimensions %d x %d.\n",hypot(coarsened.x-initial.x,coarsened.y-initial.y)*1000,atlas->width,atlas->height);
    free(plane.rgba);CVPixelBufferRelease(rgb);
} }
