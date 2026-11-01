// Exercise the production detail layer without cameras, controllers or motion.
#import "../Cerebro/ROBAccumulatedSurfaceRenderer.m"
#include <assert.h>
#include <stdio.h>

enum { W=128,H=128 };
static uint8_t depth[W*H*2],prior[W*H*2];
static void setDepth(uint8_t *data,int x,int y,unsigned mm) {size_t i=((size_t)y*W+x)*2;data[i]=mm&255;data[i+1]=mm>>8;}
static void fillDepth(unsigned mm) {for (int y=0;y<H;y++) for (int x=0;x<W;x++) setDepth(depth,x,y,mm);}
static ROBSurfacePoint position(SCNGeometrySource *source,NSUInteger index) {
    const float *v=(const float *)((const uint8_t *)source.data.bytes+source.dataOffset+index*source.dataStride);return (ROBSurfacePoint){v[0],v[1],v[2]};
}
static uint64_t hashBytes(NSData *data) {uint64_t h=1469598103934665603ull;const uint8_t *p=data.bytes;for(NSUInteger i=0;i<data.length;i++) {h^=p[i];h*=1099511628211ull;}return h;}
static NSData *photo(SCNGeometry *geometry) {
    NSBitmapImageRep *b=[[NSBitmapImageRep alloc] initWithCGImage:(__bridge CGImageRef)geometry.firstMaterial.diffuse.contents];
    return [b representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
}
int main(void) { @autoreleasepool {
    ROBSurfaceDepthView view={W,H,depth,100,100,63.5,63.5,{1,0,0,0,0,-1,0,0,0,0,-1,0}},previous=view;previous.depthLittleEndian=prior;
    ROBSurfaceMesh *mesh=calloc(1,sizeof(*mesh));assert(mesh);mesh->planeCount=1;mesh->planes[0].normal=(ROBSurfacePoint){0,0,1};mesh->planes[0].offset=1;
    CVPixelBufferRef rgb=NULL;assert(CVPixelBufferCreate(NULL,W,H,kCVPixelFormatType_32BGRA,NULL,&rgb)==kCVReturnSuccess);
    CVPixelBufferLockBaseAddress(rgb,0);uint8_t *pixels=CVPixelBufferGetBaseAddress(rgb);size_t stride=CVPixelBufferGetBytesPerRow(rgb);
    for (int y=0;y<H;y++) for (int x=0;x<W;x++) {
        setDepth(depth,x,y,x<64 ? 1100+(unsigned)(10+10*sin(y*.1)) : 1250);
        uint8_t *p=pixels+y*stride+x*4;p[0]=x;p[1]=y;p[2]=(x/3+y/3)%2 ? 255 : 0;p[3]=255;
    }
    CVPixelBufferUnlockBaseAddress(rgb,0);setDepth(depth,16,21,0);setDepth(depth,17,21,0);memcpy(prior,depth,sizeof(depth));
    ROBSurfaceDepthDetail *patch=ROBSurfaceDetailCreate(view,previous,rgb,mesh,@[],1,1);assert(patch);
    assert(patch->observedPixels==W*H-2 && patch->geometry.geometryElements.firstObject.primitiveCount==2*(W*H-2));
    SCNGeometrySource *vertices=[patch->geometry geometrySourcesForSemantic:SCNGeometrySourceSemanticVertex].firstObject;
    SCNGeometrySource *texture=[patch->geometry geometrySourcesForSemantic:SCNGeometrySourceSemanticTexcoord].firstObject;
    const uint32_t *indices=patch->geometry.geometryElements.firstObject.data.bytes;
    for (NSUInteger i=0;i<patch->observedPixels*6;i+=3) {
        NSUInteger cell=indices[i]/4;assert(indices[i+1]/4==cell && indices[i+2]/4==cell);
        int x=(int)(cell%W),y=(int)(cell/W);unsigned mm=ROBSurfaceDetailDepth(view,x,y);assert(mm);
        for(int j=0;j<3;j++) {
            ROBSurfacePoint p=position(vertices,indices[i+j]);assert(fabs(p.z+mm*.001)<1e-6);
            const float *t=(const float *)((const uint8_t *)texture.data.bytes+texture.dataOffset+indices[i+j]*texture.dataStride);
            assert(fabs(t[0]-(x+.5)/W)<1e-7 && fabs(t[1]-(y+.5)/H)<1e-7);
        }
    }
    assert(patch->bitmap.bitmapData[21*patch->bitmap.bytesPerRow+16*4+3]==0);
    assert(patch->bitmap.bitmapData[22*patch->bitmap.bytesPerRow+16*4+1]==22); // vertical orientation
    SCNGeometry *published=patch->geometry;uint64_t locked=hashBytes(photo(published));NSData *positions=vertices.data;
    for (int i=0;i<8;i++) {view.cameraToMap[3]=.003*sin(i);[patch refresh:view time:1.1+i*.1];}
    assert(patch->geometry==published && [positions isEqual:vertices.data] && hashBytes(photo(patch->geometry))==locked);
    view.cameraToMap[3]=0;
    // No duplicate ray ownership, no single-frame or unsupported geometry.
    assert(!ROBSurfaceDetailCreate(view,previous,rgb,mesh,@[patch],2,2));
    ROBSurfaceDepthView empty={0};assert(!ROBSurfaceDetailCreate(view,empty,rgb,mesh,@[],2,2));
    assert(!ROBSurfaceDetailCreate(view,previous,NULL,mesh,@[],2,2));
    fillDepth(1500);assert(!ROBSurfaceDetailCreate(view,previous,rgb,mesh,@[],2,2));
    ROBSurfaceDepthView oversized=view;oversized.width=oversized.height=2048;assert(!ROBSurfaceDetailCaptureEligible(oversized));
    memcpy(depth,prior,sizeof(depth));
    // Clip an overlapping coarse plane geometrically, preserving UVs and all
    // area outside the measured ray bundle (no draw-on-top or depth bias).
    uint32_t colors[50*50];for(int i=0;i<50*50;i++) colors[i]=0x808080FF;
    ROBSurfaceRectangle rect={0,0,50,50};ROBSurfacePlane plane={.normal={0,0,1},.offset=1.1,.u={1,0,0},.v={0,1,0},
        .originU=-25,.originV=-25,.width=50,.height=50,.rgba=colors,.rectangles=&rect,.rectangleCount=1};
    SCNNode *coarse=[SCNNode nodeWithGeometry:ROBSurfacePlaneGeometry(&plane)];ROBSurfaceDetailCutCoarseNode(coarse,@[patch]);
    SCNGeometrySource *p=[coarse.geometry geometrySourcesForSemantic:SCNGeometrySourceSemanticVertex].firstObject;
    SCNGeometrySource *uv=[coarse.geometry geometrySourcesForSemantic:SCNGeometrySourceSemanticTexcoord].firstObject;
    SCNGeometryElement *element=coarse.geometry.geometryElements.firstObject;const uint32_t *triangles=element.data.bytes;double area=0;
    for(NSInteger i=0;i<element.primitiveCount*3;i+=3) {
        ROBSurfacePoint a=position(p,triangles[i]),b=position(p,triangles[i+1]),c=position(p,triangles[i+2]);
        ROBSurfacePoint center=ROBDepthFloorScale(ROBSurfaceAdd(ROBSurfaceAdd(a,b),c),1./3);assert(![patch contains:center]);
        ROBSurfacePoint cross=ROBDepthFloorCross(ROBDepthFloorSubtract(b,a),ROBDepthFloorSubtract(c,a));area+=sqrt(ROBDepthFloorDot(cross,cross))*.5;
        for(int j=0;j<3;j++) {NSUInteger k=triangles[i+j];ROBSurfacePoint point=position(p,k);
            const float *t=(const float *)((const uint8_t *)uv.data.bytes+uv.dataOffset+k*uv.dataStride);
            assert(fabs(point.x-(-1+2*t[0]))<1e-6 && fabs(point.y-(-1+2*t[1]))<1e-6);
        }
    }
    assert(fabs(area-(4-pow(W*1.1/view.fx,2)))<1e-5);
    // Foreground and missing/edge depth retain history. Only two complete,
    // agreeing see-through observations remove it; published image stays frozen.
    NSUInteger count=patch->observedPixels;fillDepth(700);[patch refresh:view time:3];assert(patch->observedPixels==count);
    fillDepth(0);[patch refresh:view time:4];assert(patch->observedPixels==count);
    fillDepth(1500);[patch refresh:view time:5];assert(patch->observedPixels==count);
    fillDepth(0);[patch refresh:view time:5.5];assert(patch->observedPixels==count);
    fillDepth(1500);[patch refresh:view time:6];assert(patch->observedPixels==count);
    [patch refresh:view time:7];assert(patch->observedPixels==2*W+2*(H-2)); // image edges cannot see through
    assert(hashBytes(photo(published))==locked && patch->geometry!=published);
    fillDepth(0);[patch refresh:view time:100];assert(!patch->observedPixels);
    // A correctly represented plane spends no detail budget.
    fillDepth(1000);memcpy(prior,depth,sizeof(depth));assert(!ROBSurfaceDetailCreate(view,previous,rgb,mesh,@[],2,101));
    printf("Depth detail passed: %u measured pixels, no bridged holes/edges, frozen geometry/RGB across 8 pose checks, ownership/admission/budget guards, exact coarse clipping/UVs, occlusion/missing-depth retention, two-view clearing, immutable published snapshots and 90-second expiry.\n",W*H-2);
    CVPixelBufferRelease(rgb);free(mesh);
} }
