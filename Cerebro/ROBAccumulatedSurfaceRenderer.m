#import "ROBAccumulatedSurfaceRenderer.h"

@implementation ROBSurfaceTrackedNode @end

/* Orthorectified RGB keyframes in a persistent metric plane frame. A texel is
 * filled only by depth-verified RGB at that location, then retained unchanged.
 * Geometry sampling density, fit noise and exposure changes cannot repaint a
 * QR pattern every update. A reset/track expiry discards the keyframe. */
@interface ROBSurfacePhotoAtlas : NSObject {
@public
    double originU,originV,texelMeters,lastSeen;
    int width,height;
    NSMutableData *pixels;
    NSBitmapImageRep *bitmap;
    NSUInteger filled, lastTexelVisits;
    NSMutableData *missingPerTile, *coarseColors;
    int coarseOriginU,coarseOriginV,coarseWidth,coarseHeight;
}
- (void)updatePlane:(const ROBSurfacePlane *)plane view:(ROBSurfaceDepthView)view rgb:(CVPixelBufferRef)rgb;
- (CGImageRef)image;
@end

@implementation ROBSurfacePhotoAtlas
- (CGImageRef)image { return filled ? bitmap.CGImage : NULL; }
- (void)updatePlane:(const ROBSurfacePlane *)plane view:(ROBSurfaceDepthView)view rgb:(CVPixelBufferRef)rgb
{
    lastTexelVisits=0;
    if (!plane->rgba || plane->width<=0 || plane->height<=0) return;
    BOOL canPhotograph=rgb && ROBSurfaceViewValid(&view) && CVPixelBufferGetPixelFormatType(rgb)==kCVPixelFormatType_32BGRA &&
        CVPixelBufferGetWidth(rgb)==(size_t)view.width && CVPixelBufferGetHeight(rgb)==(size_t)view.height;
    // Geometry can grow/change while RGB is missing or another plane owns the
    // acquisition slot. Compose current observed colours in that case too.
    size_t coarseBytes=(size_t)plane->width*plane->height*sizeof(uint32_t);
    BOOL coarseChanged=coarseOriginU!=plane->originU || coarseOriginV!=plane->originV ||
        coarseWidth!=plane->width || coarseHeight!=plane->height || coarseColors.length!=coarseBytes ||
        memcmp(coarseColors.bytes,plane->rgba,coarseBytes);
    if (coarseChanged) {
        coarseColors=[NSMutableData dataWithBytes:plane->rgba length:coarseBytes];
        coarseOriginU=plane->originU;coarseOriginV=plane->originV;coarseWidth=plane->width;coarseHeight=plane->height;
    }
    double lowU=plane->originU*ROBSurfaceTexelSize,lowV=plane->originV*ROBSurfaceTexelSize,
        highU=lowU+plane->width*ROBSurfaceTexelSize,highV=lowV+plane->height*ROBSurfaceTexelSize;
    bool resize=!pixels || lowU<originU || lowV<originV || highU>originU+width*texelMeters || highV>originV+height*texelMeters;
    if (resize) {
        if (pixels) {lowU=fmin(lowU,originU);lowV=fmin(lowV,originV);highU=fmax(highU,originU+width*texelMeters);highV=fmax(highV,originV+height*texelMeters);}
        double size=texelMeters>0 ? texelMeters : .002;
        while (ceil((highU-lowU)/size)+2>2048 || ceil((highV-lowV)/size)+2>2048) size*=2;
        double ou=floor(lowU/size)*size,ov=floor(lowV/size)*size;
        int w=(int)ceil((highU-ou)/size),h=(int)ceil((highV-ov)/size);
        if (w<=0 || h<=0 || w>2048 || h>2048) return;
        NSMutableData *replacement=[NSMutableData dataWithLength:(size_t)w*h*sizeof(uint32_t)];
        uint32_t *output=replacement.mutableBytes;const uint32_t *old=pixels.bytes;NSUInteger retained=0;
        if (old) for (int y=0;y<h;y++) for (int x=0;x<w;x++) {
            int ox=(int)floor((ou+(x+.5)*size-originU)/texelMeters),oy=(int)floor((ov+(y+.5)*size-originV)/texelMeters);
            if (ox>=0 && ox<width && oy>=0 && oy<height) {output[(size_t)y*w+x]=old[(size_t)oy*width+ox];if (output[(size_t)y*w+x]) retained++;}
        }
        pixels=replacement;width=w;height=h;originU=ou;originV=ov;texelMeters=size;filled=retained;
        // A small counter per 16x16 tile avoids revisiting locked texels across
        // a room-sized atlas. Missing/occluded pixels remain eligible forever.
        int tilesX=(w+15)/16,tilesY=(h+15)/16;
        missingPerTile=[NSMutableData dataWithLength:(size_t)tilesX*tilesY*sizeof(uint16_t)];
        uint16_t *missing=missingPerTile.mutableBytes;
        for (int y=0;y<h;y++) for (int x=0;x<w;x++) if (!output[(size_t)y*w+x]) missing[(y/16)*tilesX+x/16]++;
    }
    uint32_t *output=pixels.mutableBytes;NSUInteger added=0;
    if (canPhotograph && CVPixelBufferLockBaseAddress(rgb,kCVPixelBufferLock_ReadOnly)==kCVReturnSuccess) {
        const uint8_t *source=CVPixelBufferGetBaseAddress(rgb);size_t stride=CVPixelBufferGetBytesPerRow(rgb);
        if (source && stride>=(size_t)view.width*4) {
            const double *m=view.cameraToMap;
            // Visibility tolerance is a perpendicular plane distance, like the fit
            // and its RMS. An optical-Z tolerance rejected valid oblique surfaces:
            // a few millimetres of depth noise can span many Z millimetres there.
            double nx=plane->normal.x*m[0]+plane->normal.y*m[4]+plane->normal.z*m[8];
            double ny=plane->normal.x*m[1]+plane->normal.y*m[5]+plane->normal.z*m[9];
            double nz=plane->normal.x*m[2]+plane->normal.y*m[6]+plane->normal.z*m[10];
            double d=plane->normal.x*m[3]+plane->normal.y*m[7]+plane->normal.z*m[11]+plane->offset;
            int tilesX=(width+15)/16,tilesY=(height+15)/16;
            uint16_t *missing=missingPerTile.mutableBytes;
            for (int ty=0;ty<tilesY;ty++) for (int tx=0;tx<tilesX;tx++) {
                size_t tile=(size_t)ty*tilesX+tx;if (!missing[tile]) continue;
                for (int y=ty*16;y<MIN(height,(ty+1)*16);y++) for (int x=tx*16;x<MIN(width,(tx+1)*16);x++) {
                    lastTexelVisits++;
                    size_t index=(size_t)y*width+x;if (output[index]) continue;
                    double u=originU+(x+.5)*texelMeters,v=originV+(y+.5)*texelMeters;
                    int cellU=(int)floor(u/ROBSurfaceTexelSize)-plane->originU,cellV=(int)floor(v/ROBSurfaceTexelSize)-plane->originV;
                    if (cellU<0 || cellU>=plane->width || cellV<0 || cellV>=plane->height || !plane->rgba[(size_t)cellV*plane->width+cellU]) continue;
                    ROBSurfacePoint p=ROBSurfaceAdd(ROBDepthFloorScale(plane->normal,-plane->offset),
                    ROBSurfaceAdd(ROBDepthFloorScale(plane->u,u),ROBDepthFloorScale(plane->v,v)));
                    double dx=p.x-m[3],dy=p.y-m[7],dz=p.z-m[11],z=m[2]*dx+m[6]*dy+m[10]*dz;
                    if (z<.15 || z>10) continue;
                    double px=view.fx*(m[0]*dx+m[4]*dy+m[8]*dz)/z+view.cx,py=view.fy*(m[1]*dx+m[5]*dy+m[9]*dz)/z+view.cy;
                    if (px<1 || px>=view.width-2 || py<1 || py>=view.height-2) continue;
                    int ix=(int)lround(px),iy=(int)lround(py);unsigned agreement=0;
                    const int ox[5]={0,-1,1,0,0},oy[5]={0,0,0,-1,1};
                    for (int j=0;j<5;j++) {
                        size_t offset=((size_t)(iy+oy[j])*view.width+ix+ox[j])*2;
                        unsigned mm=view.depthLittleEndian[offset] | ((unsigned)view.depthLittleEndian[offset+1]<<8);
                        double residual=mm*.001*(nx*(ix+ox[j]-view.cx)/view.fx+ny*(iy+oy[j]-view.cy)/view.fy+nz)+d;
                        bool matches=mm>=150 && mm<=10000 && fabs(residual)<=fmax(.018,plane->rms*3);
                        if (!j && !matches) break;
                        if (matches) agreement++;
                    }
                    if (agreement<3) continue;
                    int sx=(int)floor(px),sy=(int)floor(py);double ax=px-sx,ay=py-sy;unsigned rgbValue[3]={0};
                    for (int c=0;c<3;c++) {
                        double a=source[(size_t)sy*stride+sx*4+2-c]*(1-ax)+source[(size_t)sy*stride+(sx+1)*4+2-c]*ax;
                        double b=source[(size_t)(sy+1)*stride+sx*4+2-c]*(1-ax)+source[(size_t)(sy+1)*stride+(sx+1)*4+2-c]*ax;
                        rgbValue[c]=(unsigned)lround(a*(1-ay)+b*ay);
                    }
                    output[index]=(rgbValue[0]<<24)|(rgbValue[1]<<16)|(rgbValue[2]<<8)|255u;added++;missing[tile]--;
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(rgb,kCVPixelBufferLock_ReadOnly);
    }
    filled+=added;if (!filled || (!added && !resize && !coarseChanged && bitmap)) return;
    bitmap=[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:width pixelsHigh:height bitsPerSample:8 samplesPerPixel:4
        hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bitmapFormat:NSBitmapFormatAlphaNonpremultiplied bytesPerRow:width*4 bitsPerPixel:32];
    if (!bitmap.bitmapData) return;
    for (int y=0;y<height;y++) for (int x=0;x<width;x++) {
        uint32_t c=output[(size_t)y*width+x];
        if (!c) {
            // RGB-D holes/occlusion may prevent a photographic sample. Keep
            // observed voxel colour visible instead of covering it in gray;
            // leave output[index] empty so a later valid photo can fill it.
            int u=(int)floor((originU+(x+.5)*texelMeters)/ROBSurfaceTexelSize)-plane->originU;
            int v=(int)floor((originV+(y+.5)*texelMeters)/ROBSurfaceTexelSize)-plane->originV;
            if (u>=0 && u<plane->width && v>=0 && v<plane->height) c=plane->rgba[(size_t)v*plane->width+u];
        }
        uint8_t *p=bitmap.bitmapData+(size_t)y*bitmap.bytesPerRow+x*4;
        p[0]=(c>>24)&255;p[1]=(c>>16)&255;p[2]=(c>>8)&255;p[3]=c&255;
    }
}
@end

@implementation ROBSurfaceAccumulator {
    ROBSurfaceMap *_map;
    uint64_t _lastSequence;
    NSMutableDictionary<NSNumber *,ROBSurfacePhotoAtlas *> *_photos;
    NSUInteger _photoCursor;
}

- (instancetype)init
{
    if ((self=[super init])) { _map=ROBSurfaceMapCreate();_photos=[NSMutableDictionary dictionary]; }
    return self;
}

- (void)dealloc { ROBSurfaceMapDestroy(_map); }
- (NSUInteger)voxelCount { return _map ? _map->count : 0; }

- (SCNNode *)accumulate:(NSData *)samples view:(ROBSurfaceDepthView)view capturedAt:(double)capturedAt
               sequence:(uint64_t)sequence summary:(NSString **)summary
{
    return [self accumulate:samples view:view capturedAt:capturedAt sequence:sequence rgbPixelBuffer:NULL summary:summary];
}

- (SCNNode *)accumulate:(NSData *)samples view:(ROBSurfaceDepthView)view capturedAt:(double)capturedAt
               sequence:(uint64_t)sequence rgbPixelBuffer:(CVPixelBufferRef)rgb summary:(NSString **)summary
{
    if (!_map || !sequence || sequence<=_lastSequence || samples.length%sizeof(ROBSurfaceSample) ||
        !ROBSurfaceMapIntegrate(_map,samples.bytes,samples.length/sizeof(ROBSurfaceSample),capturedAt,&view,true)) {
        if (summary) *summary=@"view rejected · need fresh calibrated depth and overlapping geometry; Reset for a new view";
        return nil;
    }
    _lastSequence=sequence;
    ROBSurfaceMesh *mesh=ROBSurfaceMapBuildMesh(_map);
    if (!mesh) {
        if (summary) *summary=@"surface extraction unavailable";
        return nil;
    }
    SCNNode *node=ROBSurfaceMeshNode(mesh);
    for (NSNumber *key in _photos.allKeys) if (capturedAt-_photos[key]->lastSeen>90) [_photos removeObjectForKey:key];
    NSUInteger photoCount=0;
    /* Acquire/refill one photographic atlas per frame. Rebuilding every room
     * texture in one job starves fresh depth publication and causes flashes. */
    size_t selected=mesh->planeCount ? _photoCursor++%mesh->planeCount : 0;
    for (size_t i=0;i<mesh->planeCount;i++) {
        ROBSurfacePlane *plane=&mesh->planes[i];if (!plane->trackID) continue;
        NSNumber *key=@(plane->trackID);ROBSurfacePhotoAtlas *atlas=_photos[key];
        if (!atlas && rgb && i==selected && _photos.count<12) {atlas=[ROBSurfacePhotoAtlas new];_photos[key]=atlas;}
        if (!atlas) continue;
        atlas->lastSeen=capturedAt;[atlas updatePlane:plane view:view rgb:i==selected ? rgb : NULL];
        CGImageRef photo=atlas.image;if (!photo) continue;photoCount++;
        for (SCNNode *child in node.childNodes) if ([child isKindOfClass:ROBSurfaceTrackedNode.class] &&
            ((ROBSurfaceTrackedNode *)child).surfaceTrackID==plane->trackID) {
            child.geometry=ROBSurfacePlaneGeometryWithPhoto(plane,photo,atlas->originU,atlas->originV,atlas->width*atlas->texelMeters,atlas->height*atlas->texelMeters);
        }
    }
    if (summary) *summary=[NSString stringWithFormat:@"%llu frames · %zu stable voxels → %zu planes / %zu triangles + %zu points · %zu inferred cans · %lu photo planes%@",
        (unsigned long long)_map->frame,mesh->stableVoxelCount,mesh->planeCount,mesh->quadCount*2,mesh->residualCount,mesh->cylinderCount,
        (unsigned long)photoCount,
        mesh->truncated ? @" · detail limit reached" : @""];
    ROBSurfaceMeshDestroy(mesh);
    return node;
}
@end
