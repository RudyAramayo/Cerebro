/* Private display reconstruction helpers. These measured pixel footprints are
 * not collision geometry, a floor calibration, or an estimate of free space.
 * Keep the photograph and its capture rays together: flattening the floor's
 * noisy/nonplanar returns into a few global planes destroys small QR features. */
#ifndef ROBSurfaceDepthDetail_h
#define ROBSurfaceDepthDetail_h

enum { ROBSurfaceDetailTileSize=128, ROBSurfaceDetailMaximumPatches=4, ROBSurfaceDetailMaximumCapturePixels=1048576 };
typedef struct { float x,y,z,u,v; } ROBSurfaceDetailVertex;
typedef struct { ROBSurfacePoint normal; double offset; } ROBSurfaceDetailBoundary;
static inline BOOL ROBSurfaceDetailCaptureEligible(ROBSurfaceDepthView view) {
    return ROBSurfaceViewValid(&view) && (size_t)view.width*view.height<=ROBSurfaceDetailMaximumCapturePixels;
}

static inline unsigned ROBSurfaceDetailDepth(ROBSurfaceDepthView v,int x,int y) {
    if (x<0 || y<0 || x>=v.width || y>=v.height) return 0;
    const uint8_t *p=v.depthLittleEndian+((size_t)y*v.width+x)*2;
    unsigned mm=p[0]|((unsigned)p[1]<<8);return mm>=150 && mm<=6000 ? mm : 0;
}
static inline ROBSurfacePoint ROBSurfaceDetailPoint(ROBSurfaceDepthView v,double x,double y,double z) {
    double ox=(x-v.cx)*z/v.fx,oy=(y-v.cy)*z/v.fy;const double *m=v.cameraToMap;
    return (ROBSurfacePoint){m[0]*ox+m[1]*oy+m[2]*z+m[3],m[4]*ox+m[5]*oy+m[6]*z+m[7],m[8]*ox+m[9]*oy+m[10]*z+m[11]};
}
static inline bool ROBSurfaceDetailProject(ROBSurfaceDepthView v,ROBSurfacePoint p,double *x,double *y,double *z) {
    const double *m=v.cameraToMap;double dx=p.x-m[3],dy=p.y-m[7],dz=p.z-m[11];
    *z=m[2]*dx+m[6]*dy+m[10]*dz;if (*z<=.15 || !isfinite(*z)) return false;
    *x=v.fx*(m[0]*dx+m[4]*dy+m[8]*dz)/ *z+v.cx;
    *y=v.fy*(m[1]*dx+m[5]*dy+m[9]*dz)/ *z+v.cy;
    return *x>=-.5 && *y>=-.5 && *x<v.width-.5 && *y<v.height-.5;
}
static inline SCNGeometry *ROBSurfaceDetailGeometry(NSData *vertices,NSData *indices,SCNMaterial *material) {
    NSUInteger count=vertices.length/sizeof(ROBSurfaceDetailVertex);
    SCNGeometrySource *p=[SCNGeometrySource geometrySourceWithData:vertices semantic:SCNGeometrySourceSemanticVertex vectorCount:count
        floatComponents:YES componentsPerVector:3 bytesPerComponent:4 dataOffset:0 dataStride:sizeof(ROBSurfaceDetailVertex)];
    SCNGeometrySource *uv=[SCNGeometrySource geometrySourceWithData:vertices semantic:SCNGeometrySourceSemanticTexcoord vectorCount:count
        floatComponents:YES componentsPerVector:2 bytesPerComponent:4 dataOffset:3*sizeof(float) dataStride:sizeof(ROBSurfaceDetailVertex)];
    SCNGeometryElement *element=[SCNGeometryElement geometryElementWithData:indices primitiveType:SCNGeometryPrimitiveTypeTriangles
        primitiveCount:indices.length/(3*sizeof(uint32_t)) bytesPerIndex:sizeof(uint32_t)];
    SCNGeometry *geometry=[SCNGeometry geometryWithSources:@[p,uv] elements:@[element]];geometry.firstMaterial=material;return geometry;
}

@interface ROBSurfaceDepthDetail : NSObject {
@public
    uint32_t trackID;
    int left,top,width,height;
    ROBSurfaceDepthView anchor;
    ROBSurfaceDetailBoundary bounds[6];
    NSMutableData *depths,*lastSeen,*misses;
    NSBitmapImageRep *bitmap;
    SCNGeometry *geometry;
    NSUInteger observedPixels;
}
- (BOOL)contains:(ROBSurfacePoint)p;
- (void)refresh:(ROBSurfaceDepthView)view time:(double)time;
- (void)rebuild;
@end

@implementation ROBSurfaceDepthDetail
- (BOOL)contains:(ROBSurfacePoint)p {
    for (int i=0;i<6;i++) if (ROBDepthFloorDot(bounds[i].normal,p)+bounds[i].offset<0) return NO;
    return YES;
}
- (void)rebuild {
    NSMutableData *vertices=[NSMutableData dataWithLength:(size_t)width*height*4*sizeof(ROBSurfaceDetailVertex)],*indices=[NSMutableData data];
    ROBSurfaceDetailVertex *v=vertices.mutableBytes;const uint16_t *z=depths.bytes;observedPixels=0;
    for (int y=0;y<height;y++) for (int x=0;x<width;x++) {
        size_t i=(size_t)y*width+x;if (!z[i]) continue;observedPixels++;
        // One independent footprint per valid pixel. No edge ever spans two
        // depth samples; invalid returns cannot cut neighbouring valid pixels
        // out of a QR finder, or stretch a triangle across a foreground edge.
        for (int j=0;j<4;j++) {
            double px=left+x+(j%2)-.5,py=top+y+(j/2)-.5;
            ROBSurfacePoint p=ROBSurfaceDetailPoint(anchor,px,py,z[i]*.001);
            v[i*4+j]=(ROBSurfaceDetailVertex){p.x,p.y,p.z,(x+.5)/width,(y+.5)/height};
        }
        uint32_t a=(uint32_t)i*4,t[6]={a,a+1,a+2,a+1,a+3,a+2};[indices appendBytes:t length:sizeof(t)];
    }
    SCNMaterial *material=[SCNMaterial material];material.diffuse.contents=(__bridge id)bitmap.CGImage;
    material.lightingModelName=SCNLightingModelConstant;material.doubleSided=YES;
    // Every footprint samples its own pixel centre, including at triangle
    // edges. Interpolating UVs across it can sample a missing neighbour instead.
    // A second linear resampling blurs small codes; v follows CGImage rows.
    material.diffuse.magnificationFilter=SCNFilterModeNearest;material.diffuse.minificationFilter=SCNFilterModeNearest;
    material.diffuse.mipFilter=SCNFilterModeNone;material.diffuse.wrapS=SCNWrapModeClamp;material.diffuse.wrapT=SCNWrapModeClamp;
    geometry=ROBSurfaceDetailGeometry(vertices,indices,material);
}
- (void)refresh:(ROBSurfaceDepthView)view time:(double)time {
    uint16_t *z=depths.mutableBytes;double *seen=lastSeen.mutableBytes;uint8_t *missing=misses.mutableBytes;BOOL changed=NO;
    for (int y=0;y<height;y++) for (int x=0;x<width;x++) {
        size_t i=(size_t)y*width+x;if (!z[i]) continue;
        ROBSurfacePoint p=ROBSurfaceDetailPoint(anchor,left+x,top+y,z[i]*.001);double px,py,pz;
        if (ROBSurfaceDetailProject(view,p,&px,&py,&pz)) {
            int ix=(int)lround(px),iy=(int)lround(py);unsigned mm=ROBSurfaceDetailDepth(view,ix,iy);
            if (mm && fabs(mm*.001-pz)<=.02) {seen[i]=time;missing[i]=0;}
            else if (mm && mm*.001>pz+.06) {
                unsigned low=UINT_MAX,high=0;BOOL complete=YES;
                for (int dy=-1;dy<=1;dy++) for (int dx=-1;dx<=1;dx++) {
                    unsigned d=ROBSurfaceDetailDepth(view,ix+dx,iy+dy);if (!d) complete=NO;low=MIN(low,d);high=MAX(high,d);
                }
                if (complete && high-low<=30 && low*.001>pz+.06) missing[i]++;
                else missing[i]=0;
            } else missing[i]=0; // Occlusion/missing depth is not see-through.
        } else missing[i]=0;
        if (missing[i]>=2 || time-seen[i]>90) {
            if (!changed) {
                // A published SceneKit geometry may still own the old CGImage
                // on the render thread. Never mutate that image's backing data.
                NSBitmapImageRep *replacement=[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:width pixelsHigh:height
                    bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace
                    bitmapFormat:NSBitmapFormatAlphaNonpremultiplied bytesPerRow:width*4 bitsPerPixel:32];
                for (int row=0;row<height;row++) memcpy(replacement.bitmapData+row*replacement.bytesPerRow,bitmap.bitmapData+row*bitmap.bytesPerRow,width*4);
                bitmap=replacement;
            }
            z[i]=0;memset(bitmap.bitmapData+y*bitmap.bytesPerRow+x*4,0,4);changed=YES;
        }
    }
    if (changed) [self rebuild];
}
@end

static inline ROBSurfaceDetailBoundary ROBSurfaceDetailWorldBoundary(ROBSurfaceDepthView v,double x,double y,double z,double d) {
    const double *m=v.cameraToMap;ROBSurfacePoint n={m[0]*x+m[1]*y+m[2]*z,m[4]*x+m[5]*y+m[6]*z,m[8]*x+m[9]*y+m[10]*z};
    return (ROBSurfaceDetailBoundary){n,d-n.x*m[3]-n.y*m[7]-n.z*m[11]};
}

static inline ROBSurfaceDepthDetail *ROBSurfaceDetailCreate(ROBSurfaceDepthView view,ROBSurfaceDepthView previous,
    CVPixelBufferRef rgb,const ROBSurfaceMesh *mesh,NSArray<ROBSurfaceDepthDetail *> *existing,uint32_t trackID,double time) {
    if (!rgb || !mesh->planeCount || !ROBSurfaceDetailCaptureEligible(view) || !ROBSurfaceDetailCaptureEligible(previous) ||
        CVPixelBufferGetPixelFormatType(rgb)!=kCVPixelFormatType_32BGRA || CVPixelBufferGetWidth(rgb)!=(size_t)view.width ||
        CVPixelBufferGetHeight(rgb)!=(size_t)view.height || CVPixelBufferLockBaseAddress(rgb,kCVPixelBufferLock_ReadOnly)!=kCVReturnSuccess) return nil;
    const uint8_t *pixels=CVPixelBufferGetBaseAddress(rgb);size_t stride=CVPixelBufferGetBytesPerRow(rgb);
    if (!pixels || stride<(size_t)view.width*4) {CVPixelBufferUnlockBaseAddress(rgb,kCVPixelBufferLock_ReadOnly);return nil;}
    double bestScore=0;ROBSurfaceDepthDetail *best=nil;
    for (int top=0;top<view.height;top+=ROBSurfaceDetailTileSize) for (int left=0;left<view.width;left+=ROBSurfaceDetailTileSize) {
        int w=MIN(ROBSurfaceDetailTileSize,view.width-left),h=MIN(ROBSurfaceDetailTileSize,view.height-top);if (w<32 || h<32) continue;
        NSMutableData *zs=[NSMutableData dataWithLength:(size_t)w*h*sizeof(uint16_t)];uint16_t *out=zs.mutableBytes;
        NSUInteger supported=0,unrepresented=0,owned=0;double contrast=0;unsigned low=UINT_MAX,high=0;
        for (int y=0;y<h;y++) for (int x=0;x<w;x++) {
            unsigned mm=ROBSurfaceDetailDepth(view,left+x,top+y);if (!mm) continue;
            ROBSurfacePoint p=ROBSurfaceDetailPoint(view,left+x,top+y,mm*.001);double px,py,pz;
            if (!ROBSurfaceDetailProject(previous,p,&px,&py,&pz)) continue;
            unsigned old=ROBSurfaceDetailDepth(previous,(int)lround(px),(int)lround(py));
            if (!old || fabs(old*.001-pz)>.02) continue;
            supported++;BOOL covered=NO;
            for (ROBSurfaceDepthDetail *patch in existing) if ([patch contains:p]) {covered=YES;break;}
            if (covered) {owned++;continue;}
            out[(size_t)y*w+x]=mm;low=MIN(low,mm);high=MAX(high,mm);
            double residual=DBL_MAX;
            for (size_t j=0;j<mesh->planeCount;j++) residual=fmin(residual,fabs(ROBDepthFloorDot(mesh->planes[j].normal,p)+mesh->planes[j].offset));
            if (residual>.015) unrepresented++;
            if (x>0) for (int c=0;c<3;c++) contrast+=abs((int)pixels[(top+y)*stride+(left+x)*4+c]-(int)pixels[(top+y)*stride+(left+x-1)*4+c])/3.;
        }
        // Dense, independently repeated detail only; do not spend the bounded
        // budget on a sparse glass/occlusion edge or a well-represented plane.
        if (supported<(size_t)w*h*.90 || owned>supported*.10 || unrepresented<supported*.12) continue;
        double score=(double)unrepresented/(w*h)*(1+contrast/fmax(1,supported)/16);
        if (score<=bestScore) continue;
        bestScore=score;best=[ROBSurfaceDepthDetail new];best->trackID=trackID;best->left=left;best->top=top;best->width=w;best->height=h;
        best->anchor=view;best->anchor.depthLittleEndian=NULL;best->depths=zs;
        best->lastSeen=[NSMutableData dataWithLength:(size_t)w*h*sizeof(double)];best->misses=[NSMutableData dataWithLength:(size_t)w*h];
        double *seen=best->lastSeen.mutableBytes;for (int i=0;i<w*h;i++) seen[i]=time;
        best->bitmap=[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:w pixelsHigh:h bitsPerSample:8 samplesPerPixel:4
            hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bitmapFormat:NSBitmapFormatAlphaNonpremultiplied bytesPerRow:w*4 bitsPerPixel:32];
        for (int y=0;y<h;y++) for (int x=0;x<w;x++) {
            uint8_t *d=best->bitmap.bitmapData+y*best->bitmap.bytesPerRow+x*4;const uint8_t *s=pixels+(top+y)*stride+(left+x)*4;
            if (out[(size_t)y*w+x]) {d[0]=s[2];d[1]=s[1];d[2]=s[0];d[3]=255;} else memset(d,0,4);
        }
        // Replace coarse approximations only within this captured ray bundle
        // and depth slab. Clip geometry, rather than drawing through depth or
        // lifting a decal toward the camera. Actual missing pixels remain holes.
        best->bounds[0]=ROBSurfaceDetailWorldBoundary(view,1,0,-(left-.5-view.cx)/view.fx,0);
        best->bounds[1]=ROBSurfaceDetailWorldBoundary(view,-1,0,(left+w-.5-view.cx)/view.fx,0);
        best->bounds[2]=ROBSurfaceDetailWorldBoundary(view,0,1,-(top-.5-view.cy)/view.fy,0);
        best->bounds[3]=ROBSurfaceDetailWorldBoundary(view,0,-1,(top+h-.5-view.cy)/view.fy,0);
        best->bounds[4]=ROBSurfaceDetailWorldBoundary(view,0,0,1,-(low*.001-.08));
        best->bounds[5]=ROBSurfaceDetailWorldBoundary(view,0,0,-1,high*.001+.08);
    }
    CVPixelBufferUnlockBaseAddress(rgb,kCVPixelBufferLock_ReadOnly);if (best) [best rebuild];return best;
}

static inline double ROBSurfaceDetailSide(ROBSurfaceDetailVertex v,ROBSurfaceDetailBoundary b) {
    return b.normal.x*v.x+b.normal.y*v.y+b.normal.z*v.z+b.offset;
}
static inline ROBSurfaceDetailVertex ROBSurfaceDetailLerp(ROBSurfaceDetailVertex a,ROBSurfaceDetailVertex b,double t) {
    return (ROBSurfaceDetailVertex){a.x+(b.x-a.x)*t,a.y+(b.y-a.y)*t,a.z+(b.z-a.z)*t,a.u+(b.u-a.u)*t,a.v+(b.v-a.v)*t};
}
static inline int ROBSurfaceDetailClip(const ROBSurfaceDetailVertex *input,int count,ROBSurfaceDetailVertex *output,ROBSurfaceDetailBoundary b,BOOL inside) {
    int n=0;for (int i=0;i<count;i++) {
        ROBSurfaceDetailVertex a=input[i],c=input[(i+1)%count];double da=ROBSurfaceDetailSide(a,b),dc=ROBSurfaceDetailSide(c,b);
        BOOL ka=inside ? da>=0 : da<0,kc=inside ? dc>=0 : dc<0;
        if (ka) output[n++]=a;if (ka!=kc) output[n++]=ROBSurfaceDetailLerp(a,c,da/(da-dc));
    } return n;
}
static inline void ROBSurfaceDetailAppendPolygon(NSMutableData *triangles,ROBSurfaceDetailVertex *v,int count) {
    for (int i=1;i+1<count;i++) {ROBSurfaceDetailVertex t[3]={v[0],v[i],v[i+1]};[triangles appendBytes:t length:sizeof(t)];}
}
static inline void ROBSurfaceDetailCutCoarseNode(SCNNode *node,NSArray<ROBSurfaceDepthDetail *> *patches) {
    SCNGeometry *geometry=node.geometry;if (!geometry || !patches.count) return;
    SCNGeometrySource *p=[geometry geometrySourcesForSemantic:SCNGeometrySourceSemanticVertex].firstObject;
    SCNGeometrySource *uv=[geometry geometrySourcesForSemantic:SCNGeometrySourceSemanticTexcoord].firstObject;
    SCNGeometryElement *element=geometry.geometryElements.firstObject;
    if (element.primitiveType==SCNGeometryPrimitiveTypePoint) {
        NSMutableData *indices=[NSMutableData data];const uint32_t *old=element.data.bytes;
        for (NSInteger i=0;i<element.primitiveCount;i++) {
            uint32_t index=old[i];const float *v=(const float *)((const uint8_t *)p.data.bytes+p.dataOffset+index*p.dataStride);
            BOOL covered=NO;for (ROBSurfaceDepthDetail *patch in patches) if ([patch contains:(ROBSurfacePoint){v[0],v[1],v[2]}]) {covered=YES;break;}
            if (!covered) [indices appendBytes:&index length:sizeof(index)];
        }
        SCNGeometryElement *replacement=[SCNGeometryElement geometryElementWithData:indices primitiveType:SCNGeometryPrimitiveTypePoint primitiveCount:indices.length/4 bytesPerIndex:4];
        replacement.pointSize=element.pointSize;replacement.minimumPointScreenSpaceRadius=element.minimumPointScreenSpaceRadius;replacement.maximumPointScreenSpaceRadius=element.maximumPointScreenSpaceRadius;
        node.geometry=[SCNGeometry geometryWithSources:geometry.geometrySources elements:@[replacement]];node.geometry.materials=geometry.materials;return;
    }
    if (element.primitiveType!=SCNGeometryPrimitiveTypeTriangles || !uv) return;
    NSMutableData *triangles=[NSMutableData data];const uint32_t *indices=element.data.bytes;
    for (NSInteger i=0;i<element.primitiveCount*3;i++) {
        uint32_t k=indices[i];const float *v=(const float *)((const uint8_t *)p.data.bytes+p.dataOffset+k*p.dataStride);
        const float *t=(const float *)((const uint8_t *)uv.data.bytes+uv.dataOffset+k*uv.dataStride);
        ROBSurfaceDetailVertex vertex={v[0],v[1],v[2],t[0],t[1]};[triangles appendBytes:&vertex length:sizeof(vertex)];
    }
    for (ROBSurfaceDepthDetail *patch in patches) {
        NSMutableData *outside=[NSMutableData data];const ROBSurfaceDetailVertex *v=triangles.bytes;
        for (NSUInteger i=0;i<triangles.length/sizeof(*v);i+=3) {
            ROBSurfaceDetailVertex remaining[16],next[16],part[16];memcpy(remaining,v+i,3*sizeof(*v));int count=3;
            for (int b=0;b<6 && count>=3;b++) {
                int n=ROBSurfaceDetailClip(remaining,count,part,patch->bounds[b],NO);ROBSurfaceDetailAppendPolygon(outside,part,n);
                count=ROBSurfaceDetailClip(remaining,count,next,patch->bounds[b],YES);memcpy(remaining,next,count*sizeof(*v));
            }
        }
        triangles=outside;
    }
    NSMutableData *newIndices=[NSMutableData dataWithLength:triangles.length/sizeof(ROBSurfaceDetailVertex)*4];uint32_t *out=newIndices.mutableBytes;
    for (NSUInteger i=0;i<newIndices.length/4;i++) out[i]=(uint32_t)i;
    node.geometry=ROBSurfaceDetailGeometry(triangles,newIndices,geometry.firstMaterial);
}
#endif
