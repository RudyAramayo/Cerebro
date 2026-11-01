#import "ROBAccumulatedSurfaceRenderer.h"
#import <Vision/Vision.h>
#include <assert.h>

static CVPixelBufferRef loadRGB(NSString *path,int width,int height) {
    NSBitmapImageRep *image=(NSBitmapImageRep *)[NSBitmapImageRep imageRepWithContentsOfFile:path];
    assert(image && image.pixelsWide==width && image.pixelsHigh==height && image.bitsPerSample==8 && !image.isPlanar);
    assert(image.samplesPerPixel==3 || image.samplesPerPixel==4);
    CVPixelBufferRef buffer=NULL;assert(CVPixelBufferCreate(NULL,width,height,kCVPixelFormatType_32BGRA,NULL,&buffer)==kCVReturnSuccess);
    CVPixelBufferLockBaseAddress(buffer,0);uint8_t *output=CVPixelBufferGetBaseAddress(buffer);size_t stride=CVPixelBufferGetBytesPerRow(buffer);
    for (int y=0;y<height;y++) for (int x=0;x<width;x++) {
        const uint8_t *p=image.bitmapData+y*image.bytesPerRow+x*(image.bitsPerPixel/8);
        if (image.hasAlpha && (image.bitmapFormat&NSBitmapFormatAlphaFirst)) p++;
        uint8_t *d=output+y*stride+x*4;d[0]=p[2];d[1]=p[1];d[2]=p[0];d[3]=255;
    }
    CVPixelBufferUnlockBaseAddress(buffer,0);return buffer;
}
static NSArray<VNBarcodeObservation *> *nativeBarcodes(CGImageRef image) {
    if (!image) return @[];
    VNDetectBarcodesRequest *request=[VNDetectBarcodesRequest new];request.symbologies=@[VNBarcodeSymbologyQR];
    VNImageRequestHandler *handler=[[VNImageRequestHandler alloc] initWithCGImage:image options:@{}];
    NSError *error=nil;if (![handler performRequests:@[request] error:&error]) return @[];
    return request.results ?: @[];
}
static NSArray<VNBarcodeObservation *> *barcodes(CGImageRef image) {
    NSArray *native=nativeBarcodes(image);if (native.count || !image) return native;
    // QR features only a few source pixels wide can miss Vision's detector at
    // native display scale. Enlarge actual rendered pixels without inventing
    // detail. Report native-scale results separately; the old broken rendering
    // must also fail this identical two-scale test.
    size_t w=CGImageGetWidth(image)*2,h=CGImageGetHeight(image)*2;
    CGColorSpaceRef space=CGColorSpaceCreateDeviceRGB();CGContextRef context=CGBitmapContextCreate(NULL,w,h,8,w*4,space,(CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(space);assert(context);CGContextSetInterpolationQuality(context,kCGInterpolationNone);
    CGContextDrawImage(context,CGRectMake(0,0,w,h),image);CGImageRef enlarged=CGBitmapContextCreateImage(context);
    NSArray *result=nativeBarcodes(enlarged);CGImageRelease(enlarged);CGContextRelease(context);return result;
}
static NSArray *payloads(CGImageRef image) {
    NSMutableArray *found=[NSMutableArray array];
    for (VNBarcodeObservation *result in barcodes(image)) if (result.payloadStringValue) [found addObject:result.payloadStringValue];return found;
}
static uint32_t rgbAt(NSBitmapImageRep *bitmap,int x,int y) {
    NSColor *c=[[bitmap colorAtX:x y:y] colorUsingColorSpace:NSColorSpace.deviceRGBColorSpace];
    return ((uint32_t)lround(c.redComponent*255)<<24)|((uint32_t)lround(c.greenComponent*255)<<16)|((uint32_t)lround(c.blueComponent*255)<<8)|255u;
}
static ROBSurfacePoint pointAt(SCNGeometrySource *source,NSUInteger index) {
    const float *v=(const float *)((const uint8_t *)source.data.bytes+source.dataOffset+index*source.dataStride);
    return (ROBSurfacePoint){v[0],v[1],v[2]};
}
static CGPoint uvAt(SCNGeometrySource *source,NSUInteger index) {
    const float *v=(const float *)((const uint8_t *)source.data.bytes+source.dataOffset+index*source.dataStride);return CGPointMake(v[0],v[1]);
}
int main(int argc,const char *argv[]) { @autoreleasepool {
    [NSApplication sharedApplication];
    assert(argc>=3);NSString *input=@(argv[1]),*directory=[input stringByDeletingLastPathComponent],*output=@(argv[2]);
    [[NSFileManager defaultManager] createDirectoryAtPath:output withIntermediateDirectories:YES attributes:nil error:NULL];
    NSDictionary *capture=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:input] options:0 error:NULL];
    assert(capture);NSArray *frames=capture[@"frames"];assert(frames.count>=3);
    ROBSurfaceAccumulator *accumulator=[ROBSurfaceAccumulator new];NSMutableArray *results=[NSMutableArray array];
    NSMutableDictionary<NSNumber *,NSArray *> *probes=[NSMutableDictionary dictionary];
    uint64_t sequence=0;
    for (NSDictionary *frame in frames) { @autoreleasepool {
        int width=[frame[@"width"] intValue],height=[frame[@"height"] intValue];NSArray *k=frame[@"intrinsics"];
        NSString *imagePath=frame[@"imagePath"] ?: [[frame[@"depthPath"] stringByDeletingPathExtension] stringByAppendingPathExtension:@"jpg"];
        CVPixelBufferRef rgb=loadRGB([directory stringByAppendingPathComponent:imagePath],width,height);
        NSData *depth=[NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:frame[@"depthPath"]]];
        assert(depth.length==(size_t)width*height*2);
        ROBSurfaceDepthView view={width,height,depth.bytes,[k[0] doubleValue],[k[1] doubleValue],[k[2] doubleValue],[k[3] doubleValue],{1,0,0,0,0,-1,0,1.5,0,0,-1,0}};
        NSArray *pose=capture[@"initialCameraToRobotColumnMajor"];
        if (pose.count==16) for (int column=0;column<4;column++) {
            view.cameraToMap[column]=-[pose[column*4+1] doubleValue];
            view.cameraToMap[4+column]=[pose[column*4+2] doubleValue];
            view.cameraToMap[8+column]=-[pose[column*4] doubleValue];
        }
        NSMutableData *samples=[NSMutableData data];const uint8_t *mm=depth.bytes;
        CVPixelBufferLockBaseAddress(rgb,kCVPixelBufferLock_ReadOnly);const uint8_t *pixels=CVPixelBufferGetBaseAddress(rgb);size_t stride=CVPixelBufferGetBytesPerRow(rgb);
        int step=MAX(4,(int)ceil(sqrt((double)width*height/ROBSurfaceMaximumInput)));
        for (int y=0;y<height;y+=step) for (int x=0;x<width;x+=step) {
            size_t index=((size_t)y*width+x)*2;unsigned raw=mm[index]|((unsigned)mm[index+1]<<8);if (raw<150 || raw>10000) continue;
            double z=raw*.001,ox=(x-view.cx)*z/view.fx,oy=(y-view.cy)*z/view.fy;const double *m=view.cameraToMap;
            const uint8_t *p=pixels+(size_t)y*stride+x*4;
            ROBSurfaceSample sample={{m[0]*ox+m[1]*oy+m[2]*z+m[3],m[4]*ox+m[5]*oy+m[6]*z+m[7],m[8]*ox+m[9]*oy+m[10]*z+m[11]},
                ((uint32_t)p[2]<<24)|((uint32_t)p[1]<<16)|((uint32_t)p[0]<<8)|255u};
            [samples appendBytes:&sample length:sizeof(sample)];
        }
        CVPixelBufferUnlockBaseAddress(rgb,kCVPixelBufferLock_ReadOnly);
        double time=NSProcessInfo.processInfo.systemUptime;NSString *summary=nil;
        sequence++;
        SCNNode *node=[accumulator accumulate:samples view:view capturedAt:1+sequence*.5 sequence:sequence rgbPixelBuffer:rgb summary:&summary];
        double elapsed=(NSProcessInfo.processInfo.systemUptime-time)*1000;
        NSMutableArray *decoded=[NSMutableArray array],*planeIDs=[NSMutableArray array],*canIDs=[NSMutableArray array],*planeDetails=[NSMutableArray array],*canDetails=[NSMutableArray array],*detailIDs=[NSMutableArray array];
        NSUInteger detailPixels=0;
        NSUInteger checked=0,changed=0;
        for (SCNNode *child in node.childNodes) if ([child isKindOfClass:ROBSurfaceTrackedNode.class]) {
            ROBSurfaceTrackedNode *tracked=(ROBSurfaceTrackedNode *)child;
            if (tracked.depthDetailTrackID) {
                [detailIDs addObject:@(tracked.depthDetailTrackID)];
                CGImageRef image=(__bridge CGImageRef)child.geometry.firstMaterial.diffuse.contents;
                NSBitmapImageRep *bitmap=[[NSBitmapImageRep alloc] initWithCGImage:image];[decoded addObjectsFromArray:payloads(image)];
                SCNGeometrySource *vertices=[child.geometry geometrySourcesForSemantic:SCNGeometrySourceSemanticVertex].firstObject;
                SCNGeometryElement *element=child.geometry.geometryElements.firstObject;const uint32_t *indices=element.data.bytes;
                NSMutableIndexSet *valid=[NSMutableIndexSet indexSet];for (NSInteger i=0;i<element.primitiveCount*3;i+=6) [valid addIndex:indices[i]/4];
                detailPixels+=valid.count;NSNumber *key=@(UINT32_MAX-tracked.depthDetailTrackID);
                NSArray *previous=probes[key];NSMutableArray *newProbes=[NSMutableArray array];
                // Compare every retained, represented pixel, including its
                // world position. Decoding a full source image alone is not a
                // test that those pixels survived into geometry.
                for (NSUInteger i=valid.firstIndex;i!=NSNotFound;i=[valid indexGreaterThanIndex:i]) {
                    int x=(int)(i%bitmap.pixelsWide),y=(int)(i/bitmap.pixelsWide);ROBSurfacePoint world={0};
                    for (int j=0;j<4;j++) world=ROBSurfaceAdd(world,ROBDepthFloorScale(pointAt(vertices,i*4+j),.25));
                    uint32_t rgba=rgbAt(bitmap,x,y);
                    [newProbes addObject:@{@"pixel":@(i),@"world":[NSValue valueWithBytes:&world objCType:@encode(ROBSurfacePoint)],@"rgba":@(rgba)}];
                }
                for (NSDictionary *probe in previous) {
                    NSUInteger i=[probe[@"pixel"] unsignedIntegerValue];if (![valid containsIndex:i]) continue;
                    ROBSurfacePoint before,world={0};[probe[@"world"] getValue:&before];for (int j=0;j<4;j++) world=ROBSurfaceAdd(world,ROBDepthFloorScale(pointAt(vertices,i*4+j),.25));
                    ROBSurfacePoint delta=ROBDepthFloorSubtract(world,before);checked++;
                    if (ROBDepthFloorDot(delta,delta)>1e-12 || rgbAt(bitmap,(int)(i%bitmap.pixelsWide),(int)(i/bitmap.pixelsWide))!=[probe[@"rgba"] unsignedIntValue]) changed++;
                }
                if (!previous) probes[key]=newProbes;
                [[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:[output stringByAppendingPathComponent:[NSString stringWithFormat:@"frame-%llu-detail-%u.png",(unsigned long long)sequence,tracked.depthDetailTrackID]] atomically:YES];
            }
            if (tracked.cylinderTrackID) {
                [canIDs addObject:@(tracked.cylinderTrackID)];SCNVector3 p=tracked.position;const double *m=view.cameraToMap;
                double dx=p.x-m[3],dy=p.y-m[7],dz=p.z-m[11],z=m[2]*dx+m[6]*dy+m[10]*dz;
                [canDetails addObject:@{@"id":@(tracked.cylinderTrackID),@"pixel":@[@(view.fx*(m[0]*dx+m[4]*dy+m[8]*dz)/z+view.cx),@(view.fy*(m[1]*dx+m[5]*dy+m[9]*dz)/z+view.cy)]}];
            }
            if (tracked.surfaceTrackID) {
                [planeIDs addObject:@(tracked.surfaceTrackID)];CGImageRef image=(__bridge CGImageRef)child.geometry.firstMaterial.diffuse.contents;
                SCNGeometryElement *element=child.geometry.geometryElements.firstObject;if (!element.primitiveCount) continue;
                const uint32_t *indices=element.data.bytes;
                SCNGeometrySource *vertices=[child.geometry geometrySourcesForSemantic:SCNGeometrySourceSemanticVertex].firstObject;
                ROBSurfacePoint a=pointAt(vertices,indices[0]),b=pointAt(vertices,indices[1]),c=pointAt(vertices,indices[2]);
                ROBSurfacePoint normal=ROBDepthFloorCross(ROBDepthFloorSubtract(b,a),ROBDepthFloorSubtract(c,a));
                normal=ROBDepthFloorScale(normal,1/sqrt(ROBDepthFloorDot(normal,normal)));
                [planeDetails addObject:@{@"id":@(tracked.surfaceTrackID),@"normal":@[@(normal.x),@(normal.y),@(normal.z)],@"offset":@(-ROBDepthFloorDot(normal,a))}];
                [decoded addObjectsFromArray:payloads(image)];
                NSBitmapImageRep *bitmap=[[NSBitmapImageRep alloc] initWithCGImage:image];
                SCNGeometrySource *texture=[child.geometry geometrySourcesForSemantic:SCNGeometrySourceSemanticTexcoord].firstObject;
                CGPoint ta=uvAt(texture,indices[0]),tb=uvAt(texture,indices[1]),tc=uvAt(texture,indices[2]);
                ROBSurfacePoint edgeU=ROBDepthFloorSubtract(b,a),edgeV=ROBDepthFloorSubtract(c,a);
                double uu=ROBDepthFloorDot(edgeU,edgeU),uv=ROBDepthFloorDot(edgeU,edgeV),vv=ROBDepthFloorDot(edgeV,edgeV),det=uu*vv-uv*uv;
                double textureDet=(tb.x-ta.x)*(tc.y-ta.y)-(tb.y-ta.y)*(tc.x-ta.x);if (fabs(det)<1e-16 || fabs(textureDet)<1e-16) continue;
                NSNumber *key=@(tracked.surfaceTrackID);NSArray *previous=probes[key];
                if (previous) for (NSDictionary *probe in previous) {
                    ROBSurfacePoint world;[probe[@"world"] getValue:&world];ROBSurfacePoint delta=ROBDepthFloorSubtract(world,a);
                    double du=ROBDepthFloorDot(delta,edgeU),dv=ROBDepthFloorDot(delta,edgeV),alpha=(du*vv-dv*uv)/det,beta=(dv*uu-du*uv)/det;
                    double u=ta.x+alpha*(tb.x-ta.x)+beta*(tc.x-ta.x),v=ta.y+alpha*(tb.y-ta.y)+beta*(tc.y-ta.y);
                    int x=(int)floor(u*bitmap.pixelsWide),y=(int)floor(v*bitmap.pixelsHigh);
                    if (x>=0 && x<bitmap.pixelsWide && y>=0 && y<bitmap.pixelsHigh) {checked++;if (rgbAt(bitmap,x,y)!=[probe[@"rgba"] unsignedIntValue]) changed++;}
                }
                if (!previous) {
                    NSMutableArray *newProbes=[NSMutableArray array];
                    for (VNBarcodeObservation *code in barcodes(image)) for (int y=0;y<5;y++) for (int x=0;x<5;x++) {
                        CGRect box=code.boundingBox;
                        int px=(int)floor((box.origin.x+box.size.width*(x+.5)/5)*bitmap.pixelsWide),py=(int)floor((1-box.origin.y-box.size.height*(y+.5)/5)*bitmap.pixelsHigh);
                        if (px<0 || px>=bitmap.pixelsWide || py<0 || py>=bitmap.pixelsHigh) continue;
                        uint32_t rgba=rgbAt(bitmap,px,py);if (rgba==0x70808CFF) continue;
                        double u=(px+.5)/bitmap.pixelsWide,v=(py+.5)/bitmap.pixelsHigh;
                        double alpha=((u-ta.x)*(tc.y-ta.y)-(v-ta.y)*(tc.x-ta.x))/textureDet,beta=((v-ta.y)*(tb.x-ta.x)-(u-ta.x)*(tb.y-ta.y))/textureDet;
                        ROBSurfacePoint world=ROBSurfaceAdd(a,ROBSurfaceAdd(ROBDepthFloorScale(edgeU,alpha),ROBDepthFloorScale(edgeV,beta)));
                        [newProbes addObject:@{@"world":[NSValue valueWithBytes:&world objCType:@encode(ROBSurfacePoint)],@"rgba":@(rgba)}];
                    }
                    if (newProbes.count) probes[key]=newProbes;
                }
                NSString *path=[output stringByAppendingPathComponent:[NSString stringWithFormat:@"frame-%llu-plane-%u.png",(unsigned long long)sequence,tracked.surfaceTrackID]];
                [[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES];
            }
        }
        NSBitmapImageRep *source=(NSBitmapImageRep *)[NSBitmapImageRep imageRepWithContentsOfFile:[directory stringByAppendingPathComponent:imagePath]];
        NSArray *renderedQR=@[],*renderedNativeResolutionQR=@[];double maxCornerError=0;
        if (node.childNodes.count) {
            SCNScene *scene=[SCNScene scene];scene.background.contents=NSColor.darkGrayColor;[scene.rootNode addChildNode:node];
            SCNNode *camera=[SCNNode node];camera.camera=[SCNCamera camera];
            const double *m=view.cameraToMap;
            SCNMatrix4 transform=SCNMatrix4Identity;
            transform.m11=m[0];transform.m12=m[4];transform.m13=m[8];
            transform.m21=-m[1];transform.m22=-m[5];transform.m23=-m[9];
            transform.m31=-m[2];transform.m32=-m[6];transform.m33=-m[10];
            transform.m41=m[3];transform.m42=m[7];transform.m43=m[11];camera.transform=transform;
            SCNMatrix4 projection=SCNMatrix4Identity;
            projection.m11=2*view.fx/width;projection.m22=2*view.fy/height;
            projection.m31=1-2*view.cx/width;projection.m32=2*view.cy/height-1;
            projection.m33=-(10+.01)/(10-.01);projection.m34=-1;projection.m43=-2*10*.01/(10-.01);projection.m44=0;
            camera.camera.projectionTransform=projection;[scene.rootNode addChildNode:camera];
            SCNRenderer *renderer=[SCNRenderer rendererWithDevice:nil options:nil];renderer.scene=scene;renderer.pointOfView=camera;
            NSImage *picture=[renderer snapshotAtTime:0 withSize:CGSizeMake(width,height) antialiasingMode:SCNAntialiasingModeMultisampling4X];
            NSBitmapImageRep *rendered=[NSBitmapImageRep imageRepWithData:picture.TIFFRepresentation];assert(rendered);
            NSString *path=[output stringByAppendingPathComponent:[NSString stringWithFormat:@"frame-%llu-rendered.png",(unsigned long long)sequence]];
            [[rendered representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES];
            renderedQR=payloads(rendered.CGImage);
            NSMutableArray *nativeScale=[NSMutableArray array];for (VNBarcodeObservation *code in nativeBarcodes(rendered.CGImage)) if (code.payloadStringValue) [nativeScale addObject:code.payloadStringValue];renderedNativeResolutionQR=nativeScale;
            for (VNBarcodeObservation *before in barcodes(source.CGImage)) for (VNBarcodeObservation *after in barcodes(rendered.CGImage)) if ([before.payloadStringValue isEqual:after.payloadStringValue]) {
                CGPoint a[4]={before.topLeft,before.topRight,before.bottomRight,before.bottomLeft},b[4]={after.topLeft,after.topRight,after.bottomRight,after.bottomLeft};
                for (int j=0;j<4;j++) maxCornerError=fmax(maxCornerError,hypot((a[j].x-b[j].x)*width,(a[j].y-b[j].y)*height));
            }
        }
        NSDictionary *record=@{@"frame":@(sequence),@"summary":summary ?: @"",@"milliseconds":@(elapsed),@"planeIDs":planeIDs,@"canIDs":canIDs,
            @"reconstructedQR":decoded,@"nativeQR":payloads(source.CGImage),@"planes":planeDetails,@"cans":canDetails,
            @"textureProbesCompared":@(checked),@"textureProbesChanged":@(changed),@"renderedQR":renderedQR,
            @"renderedNativeResolutionQR":renderedNativeResolutionQR,@"maxRenderQRCornerErrorPixels":@(maxCornerError),@"detailIDs":detailIDs,@"detailPixels":@(detailPixels)};
        [results addObject:record];printf("%s\n",[[[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:record options:NSJSONWritingSortedKeys error:NULL] encoding:NSUTF8StringEncoding] UTF8String]);
        CVPixelBufferRelease(rgb);
    } }
    [[NSJSONSerialization dataWithJSONObject:@{@"input":input,@"frames":results} options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:NULL]
        writeToFile:[output stringByAppendingPathComponent:@"report.json"] atomically:YES];
} }
