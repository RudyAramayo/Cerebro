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
    // The locked QR must not change. Unphotographed border fallback is allowed
    // to refresh as measured voxel colours improve.
    VNDetectBarcodesRequest *request=[VNDetectBarcodesRequest new];request.symbologies=@[VNBarcodeSymbologyQR];
    VNImageRequestHandler *handler=[[VNImageRequestHandler alloc] initWithCGImage:image options:@{}];
    assert([handler performRequests:@[request] error:NULL]);
    VNBarcodeObservation *code=request.results.firstObject;assert(code);
    static CGRect region={0};
    if (CGRectIsEmpty(region)) {
        CGRect b=code.boundingBox;
        region=CGRectIntegral(CGRectMake(b.origin.x*CGImageGetWidth(image),(1-CGRectGetMaxY(b))*CGImageGetHeight(image),
            b.size.width*CGImageGetWidth(image),b.size.height*CGImageGetHeight(image)));
    }
    NSBitmapImageRep *bitmap=[[NSBitmapImageRep alloc] initWithCGImage:image];
    uint64_t hash=1469598103934665603ull;
    for (NSInteger y=CGRectGetMinY(region);y<CGRectGetMaxY(region);y++) for (NSInteger x=CGRectGetMinX(region);x<CGRectGetMaxX(region);x++) {
        NSUInteger pixel[4]={0};[bitmap getPixel:pixel atX:x y:y];
        for(int c=0;c<4;c++) {hash^=pixel[c];hash*=1099511628211ull;}
    }
    return hash;
}
static CGPoint qrCenter(CGImageRef image) {
    VNDetectBarcodesRequest *request=[VNDetectBarcodesRequest new];request.symbologies=@[VNBarcodeSymbologyQR];
    VNImageRequestHandler *handler=[[VNImageRequestHandler alloc] initWithCGImage:image options:@{}];
    assert([handler performRequests:@[request] error:NULL]);
    for (VNBarcodeObservation *code in request.results) if ([code.payloadStringValue isEqual:@"ROB:STABLE:SURFACE"])
        return CGPointMake(CGRectGetMidX(code.boundingBox)*CGImageGetWidth(image),CGRectGetMidY(code.boundingBox)*CGImageGetHeight(image));
    return CGPointMake(NAN,NAN);
}
static NSBitmapImageRep *render(SCNNode *node,int width,int height,double fx,double fy,double cx,double cy) {
    SCNScene *scene=[SCNScene scene];scene.background.contents=NSColor.darkGrayColor;[scene.rootNode addChildNode:node];
    SCNNode *camera=[SCNNode node];camera.camera=[SCNCamera camera];
    SCNMatrix4 p=SCNMatrix4Identity;p.m11=2*fx/width;p.m22=2*fy/height;
    p.m31=1-2*cx/width;p.m32=2*cy/height-1;p.m33=-(10+.01)/(10-.01);p.m34=-1;p.m43=-2*10*.01/(10-.01);p.m44=0;
    camera.camera.projectionTransform=p;[scene.rootNode addChildNode:camera];
    SCNRenderer *renderer=[SCNRenderer rendererWithDevice:nil options:nil];renderer.scene=scene;renderer.pointOfView=camera;
    NSImage *image=[renderer snapshotAtTime:0 withSize:CGSizeMake(width,height) antialiasingMode:SCNAntialiasingModeMultisampling4X];
    return [NSBitmapImageRep imageRepWithData:image.TIFFRepresentation];
}
static void grazingAndMissingRGB(void) {
    enum {width=320,height=320};
    CVPixelBufferRef rgb=NULL;assert(CVPixelBufferCreate(NULL,width,height,kCVPixelFormatType_32BGRA,NULL,&rgb)==kCVReturnSuccess);
    CVPixelBufferLockBaseAddress(rgb,0);uint8_t *color=CVPixelBufferGetBaseAddress(rgb);size_t stride=CVPixelBufferGetBytesPerRow(rgb);
    uint8_t depth[width*height*2];memset(depth,0,sizeof(depth));NSMutableData *samples=[NSMutableData data];
    for (int y=0;y<height;y++) for (int x=0;x<width;x++) {
        uint32_t rgba=(x/64)%2 ? 0xD02010FF : 0x1030D0FF;uint8_t *p=color+y*stride+x*4;
        p[0]=(rgba>>8)&255;p[1]=(rgba>>16)&255;p[2]=(rgba>>24)&255;p[3]=255;
        if (y<152 || y>=232) continue;
        double ray=.995*(y-159.5)/240.+.1;
        /* Six mm normal noise becomes 15–90 mm along camera Z. Correct
         * surface evidence must not turn gray merely because rays graze it. */
        double z=(.2+(((x*17+y*11)%2) ? .006 : -.006))/ray;
        unsigned mm=(unsigned)lround(z*1000);depth[(y*width+x)*2]=mm&255;depth[(y*width+x)*2+1]=mm>>8;
        if (x%4 || y%4) continue;
        z=mm*.001;ROBSurfaceSample s={{(x-159.5)*z/240.,-(y-159.5)*z/240.,-z},rgba};[samples appendBytes:&s length:sizeof(s)];
    }
    CVPixelBufferUnlockBaseAddress(rgb,0);
    ROBSurfaceDepthView view={width,height,depth,240,240,159.5,159.5,{1,0,0,0,0,-1,0,0,0,0,-1,0}};
    ROBSurfaceAccumulator *accumulator=[ROBSurfaceAccumulator new],*withoutRGB=[ROBSurfaceAccumulator new];ROBSurfaceMap *reference=ROBSurfaceMapCreate();
    SCNNode *node=nil,*colorOnly=nil;
    for (int frame=1;frame<=2;frame++) {
        assert(ROBSurfaceMapIntegrate(reference,samples.bytes,samples.length/sizeof(ROBSurfaceSample),frame,&view,true));
        ROBSurfaceMesh *warm=ROBSurfaceMapBuildMesh(reference);ROBSurfaceMeshDestroy(warm);
        node=[accumulator accumulate:samples view:view capturedAt:frame sequence:frame rgbPixelBuffer:rgb summary:NULL];
        colorOnly=[withoutRGB accumulate:samples view:view capturedAt:frame sequence:frame summary:NULL];
    }
    ROBSurfaceTrackedNode *plane=nil;
    for (SCNNode *child in node.childNodes) if ([child isKindOfClass:ROBSurfaceTrackedNode.class] && ((ROBSurfaceTrackedNode *)child).surfaceTrackID && child.geometry) {plane=(ROBSurfaceTrackedNode *)child;break;}
    assert(plane);NSBitmapImageRep *image=[[NSBitmapImageRep alloc] initWithCGImage:(__bridge CGImageRef)plane.geometry.firstMaterial.diffuse.contents];
    assert(!plane.geometry.firstMaterial.writesToDepthBuffer);
    SCNGeometrySource *vertex=[plane.geometry geometrySourcesForSemantic:SCNGeometrySourceSemanticVertex].firstObject,*texture=[plane.geometry geometrySourcesForSemantic:SCNGeometrySourceSemanticTexcoord].firstObject;
    const float *p=vertex.data.bytes,*uv=texture.data.bytes;
    ROBSurfacePoint a={p[0],p[1],p[2]},u={p[3]-p[0],p[4]-p[1],p[5]-p[2]},v={p[9]-p[0],p[10]-p[1],p[11]-p[2]};
    ROBSurfaceMesh *mesh=ROBSurfaceMapBuildMesh(reference);size_t compared=0,matched=0;
    for (size_t i=0;i<mesh->planeSampleCount;i++) {
        ROBSurfaceSample s=mesh->planeSamples[i];ROBSurfacePoint d=ROBDepthFloorSubtract(s.point,a);
        double tu=uv[0]+ROBDepthFloorDot(d,u)/ROBDepthFloorDot(u,u)*(uv[2]-uv[0]),tv=uv[1]+ROBDepthFloorDot(d,v)/ROBDepthFloorDot(v,v)*(uv[7]-uv[1]);
        int x=(int)floor(tu*image.pixelsWide),y=(int)floor(tv*image.pixelsHigh);
        if (x<0 || x>=image.pixelsWide || y<0 || y>=image.pixelsHigh) continue;
        compared++;NSColor *c=[[image colorAtX:x y:y] colorUsingColorSpace:NSColorSpace.deviceRGBColorSpace];
        if (c.alphaComponent>.99 && fabs(c.redComponent-((s.rgba>>24)&255)/255.)<.08 &&
            fabs(c.greenComponent-((s.rgba>>16)&255)/255.)<.08 && fabs(c.blueComponent-((s.rgba>>8)&255)/255.)<.08) matched++;
    }
    assert(compared>500 && matched>compared*.80);
    NSBitmapImageRep *atlas=image;NSUInteger transparent=0,gray=0;
    const uint8_t *pixels=atlas.bitmapData;
    for (NSInteger y=0;y<atlas.pixelsHigh;y++) for (NSInteger x=0;x<atlas.pixelsWide;x++) {
        const uint8_t *pixel=pixels+y*atlas.bytesPerRow+x*(atlas.bitsPerPixel/8);
        if (!pixel[3]) transparent++;
        if (pixel[0]==0x70 && pixel[1]==0x80 && pixel[2]==0x8c && pixel[3]) gray++;
    }
    assert(transparent && !gray);
    SCNNode *fallback=[colorOnly childNodeWithName:@"Measured RGB surface voxels · photographic fallback" recursively:NO];assert(fallback.geometry);
    for (SCNNode *child in colorOnly.childNodes) if ([child.name hasPrefix:@"Observed plane"]) assert(!child.geometry);
    ROBSurfaceMeshDestroy(mesh);ROBSurfaceMapDestroy(reference);CVPixelBufferRelease(rgb);
    printf("Grazing-color reconstruction passed: %zu/%zu voxel colors match photo RGB, unknown texels transparent, no opaque gray/depth blanket; no-image frames preserve measured color points.\n",matched,compared);
}
static void checkObliqueCoverage(void) {
    enum {w=160,h=120};uint8_t depth[w*h*2];
    CVPixelBufferRef rgb=NULL;assert(CVPixelBufferCreate(NULL,w,h,kCVPixelFormatType_32BGRA,NULL,&rgb)==kCVReturnSuccess);
    ROBSurfaceDepthView view={w,h,depth,600,600,79.5,59.5,{1,0,0,0,0,-1,0,0,0,0,-1,0}};
    ROBSurfaceAccumulator *map=[ROBSurfaceAccumulator new];
    for (int frame=1;frame<=3;frame++) {
        NSMutableData *samples=[NSMutableData data];uint32_t color=frame==3 ? 0xD02010FF : 0x10D020FF;
        CVPixelBufferLockBaseAddress(rgb,0);uint8_t *pixels=CVPixelBufferGetBaseAddress(rgb);size_t stride=CVPixelBufferGetBytesPerRow(rgb);
        for (int y=0;y<h;y++) for (int x=0;x<w;x++) {
            // 80-degree plane. Six mm of perpendicular capture noise gives
            // ~35 mm of optical-Z error at the centre, yet fits the same plane.
            double z=(cos(80*M_PI/180)+(frame==3 ? .006 : 0))/(cos(80*M_PI/180)-sin(80*M_PI/180)*(y-view.cy)/view.fy);
            unsigned mm=(unsigned)lround(z*1000);size_t i=((size_t)y*w+x)*2;depth[i]=mm&255;depth[i+1]=mm>>8;
            uint8_t *p=pixels+(size_t)y*stride+x*4;p[0]=(color>>8)&255;p[1]=(color>>16)&255;p[2]=(color>>24)&255;p[3]=255;
            if (x%2==0 && y%2==0) {ROBSurfaceSample s={{(x-view.cx)*z/view.fx,-(y-view.cy)*z/view.fy,-z},color};[samples appendBytes:&s length:sizeof(s)];}
        }
        CVPixelBufferUnlockBaseAddress(rgb,0);
        NSString *summary=nil;
        SCNNode *node=[map accumulate:samples view:view capturedAt:frame*.25 sequence:frame rgbPixelBuffer:frame==3 ? rgb : NULL summary:&summary];assert(node);
        if (frame==3) {
            NSBitmapImageRep *picture=render(node,w,h,view.fx,view.fy,view.cx,view.cy);
            NSColor *c=[[picture colorAtX:w/2 y:h/2] colorUsingColorSpace:NSColorSpace.deviceRGBColorSpace];
            printf("Oblique coverage: %s; centre RGB %.3f %.3f %.3f\n",summary.UTF8String,c.redComponent,c.greenComponent,c.blueComponent);fflush(stdout);
            assert(c.redComponent>.7 && c.redComponent>3*c.greenComponent);
        }
    }
    CVPixelBufferRelease(rgb);
}
int main(int argc,const char *argv[]) { @autoreleasepool {
    [NSApplication sharedApplication];
    enum {width=480,height=360};
    CVPixelBufferRef rgb=NULL;assert(CVPixelBufferCreate(NULL,width,height,kCVPixelFormatType_32BGRA,NULL,&rgb)==kCVReturnSuccess);
    CIFilter *filter=[CIFilter filterWithName:@"CIQRCodeGenerator"];
    [filter setValue:[@"ROB:STABLE:SURFACE" dataUsingEncoding:NSUTF8StringEncoding] forKey:@"inputMessage"];
    [filter setValue:@"H" forKey:@"inputCorrectionLevel"];
    CIImage *code=[filter.outputImage imageByApplyingTransform:CGAffineTransformMakeScale(6,6)];
    // Off-centre placement exposes flips/translations that a readable centred
    // QR and a stable atlas hash cannot detect.
    code=[code imageByApplyingTransform:CGAffineTransformMakeTranslation(25,35)];
    CIContext *context=[CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer:@YES}];
    uint8_t depth[width*height*2];for (int i=0;i<width*height;i++) {depth[i*2]=0xE8;depth[i*2+1]=3;}
    ROBSurfaceDepthView view={width,height,depth,240,240,239.5,179.5,{1,0,0,0,0,-1,0,0,0,0,-1,0}};
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
            ROBSurfaceSample sample={{(x-view.cx)/view.fx,-(y-view.cy)/view.fy,-1},((uint32_t)p[2]<<24)|((uint32_t)p[1]<<16)|((uint32_t)p[0]<<8)|255u};
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
        if (frame==12) {
            CGImageRef native=[context createCGImage:[CIImage imageWithCVPixelBuffer:rgb] fromRect:CGRectMake(0,0,width,height)];
            NSBitmapImageRep *picture=render(node,width,height,view.fx,view.fy,view.cx,view.cy);
            CGPoint a=qrCenter(native),b=qrCenter(picture.CGImage);
            double error=hypot(a.x-b.x,a.y-b.y);printf("QR source/render centre error: %.3f pixels (%.1f,%.1f) -> (%.1f,%.1f)\n",error,a.x,a.y,b.x,b.y);fflush(stdout);
            if (argc>1) [[picture representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:[@(argv[1]) stringByAppendingString:@"-render.png"] atomically:YES];
            CGImageRelease(native);assert(isfinite(error) && error<2);
        }
        if (frame==12 && argc>1) {
            NSBitmapImageRep *bitmap=[[NSBitmapImageRep alloc] initWithCGImage:atlas];
            assert([[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:@(argv[1]) atomically:YES]);
        }
    } }
    CVPixelBufferRelease(rgb);
    grazingAndMissingRGB();
    checkObliqueCoverage();
    printf("Photographic surface passed: %zu consecutive QR decodes, source/render alignment, same plane identity, bit-identical keyframe despite exposure changes, measured colour without RGB, transparent gaps with measured-point fallback and noisy oblique-plane coverage; no camera/actuator IO.\n",decoded);
} }
