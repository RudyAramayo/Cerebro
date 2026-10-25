#ifndef ROBAccumulatedSurfaceRenderer_h
#define ROBAccumulatedSurfaceRenderer_h
#import <AppKit/AppKit.h>
#import <SceneKit/SceneKit.h>
#include "ROBAccumulatedSurfaceMap.h"

/* All vertices remain in physical submap metres. The caller applies exactly
 * one presentation scale and the base placement captured for this submap. */
static inline SCNGeometry *ROBSurfacePlaneGeometry(const ROBSurfacePlane *plane) {
    size_t count=plane->rectangleCount*4;
    if (!count || !plane->rgba) return nil;
    typedef struct { float x,y,z; } Vertex;
    typedef struct { float u,v; } UV;
    NSMutableData *positions=[NSMutableData dataWithLength:count*sizeof(Vertex)];
    NSMutableData *texcoords=[NSMutableData dataWithLength:count*sizeof(UV)];
    NSMutableData *indices=[NSMutableData dataWithLength:plane->rectangleCount*6*sizeof(uint32_t)];
    Vertex *vertices=positions.mutableBytes;UV *uv=texcoords.mutableBytes;uint32_t *triangles=indices.mutableBytes;
    for (size_t i=0;i<plane->rectangleCount;i++) {
        ROBSurfaceRectangle r=plane->rectangles[i];
        double x[4]={r.x,r.x+r.width,r.x+r.width,r.x},y[4]={r.y,r.y,r.y+r.height,r.y+r.height};
        for (size_t j=0;j<4;j++) {
            ROBSurfacePoint p=ROBSurfaceAdd(ROBDepthFloorScale(plane->normal,-plane->offset),
                ROBSurfaceAdd(ROBDepthFloorScale(plane->u,(plane->originU+x[j])*ROBSurfaceTexelSize),
                              ROBDepthFloorScale(plane->v,(plane->originV+y[j])*ROBSurfaceTexelSize)));
            vertices[i*4+j]=(Vertex){(float)p.x,(float)p.y,(float)p.z};
            uv[i*4+j]=(UV){(float)(x[j]/plane->width),(float)(1-y[j]/plane->height)};
        }
        uint32_t b=(uint32_t)(i*4);uint32_t t[6]={b,b+1,b+2,b,b+2,b+3};memcpy(triangles+i*6,t,sizeof(t));
    }
    SCNGeometrySource *vertex=[SCNGeometrySource geometrySourceWithData:positions semantic:SCNGeometrySourceSemanticVertex
        vectorCount:count floatComponents:YES componentsPerVector:3 bytesPerComponent:sizeof(float) dataOffset:0 dataStride:sizeof(Vertex)];
    SCNGeometrySource *texture=[SCNGeometrySource geometrySourceWithData:texcoords semantic:SCNGeometrySourceSemanticTexcoord
        vectorCount:count floatComponents:YES componentsPerVector:2 bytesPerComponent:sizeof(float) dataOffset:0 dataStride:sizeof(UV)];
    SCNGeometryElement *element=[SCNGeometryElement geometryElementWithData:indices primitiveType:SCNGeometryPrimitiveTypeTriangles
        primitiveCount:plane->rectangleCount*2 bytesPerIndex:sizeof(uint32_t)];
    SCNGeometry *geometry=[SCNGeometry geometryWithSources:@[vertex,texture] elements:@[element]];
    NSBitmapImageRep *bitmap=[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:plane->width pixelsHigh:plane->height
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace
        bitmapFormat:NSBitmapFormatAlphaNonpremultiplied bytesPerRow:plane->width*4 bitsPerPixel:32];
    if (!bitmap.bitmapData) return nil;
    for (int y=0;y<plane->height;y++) for (int x=0;x<plane->width;x++) {
        uint32_t c=plane->rgba[(size_t)y*plane->width+x];uint8_t *pixel=bitmap.bitmapData+y*bitmap.bytesPerRow+x*4;
        pixel[0]=(c>>24)&255;pixel[1]=(c>>16)&255;pixel[2]=(c>>8)&255;pixel[3]=c&255;
    }
    SCNMaterial *material=[SCNMaterial material];material.diffuse.contents=(__bridge id)bitmap.CGImage;
    material.lightingModelName=SCNLightingModelConstant;material.doubleSided=YES;
    material.diffuse.minificationFilter=SCNFilterModeNearest;material.diffuse.magnificationFilter=SCNFilterModeNearest;
    material.diffuse.mipFilter=SCNFilterModeNone;geometry.firstMaterial=material;return geometry;
}
static inline SCNGeometry *ROBSurfaceResidualGeometry(const ROBSurfaceMesh *mesh) {
    if (!mesh->residualCount) return nil;
    typedef struct { float x,y,z; } Vertex;
    typedef struct { float r,g,b,a; } Color;
    NSMutableData *positions=[NSMutableData dataWithLength:mesh->residualCount*sizeof(Vertex)],
        *colors=[NSMutableData dataWithLength:mesh->residualCount*sizeof(Color)],
        *indices=[NSMutableData dataWithLength:mesh->residualCount*sizeof(uint32_t)];
    Vertex *v=positions.mutableBytes;Color *c=colors.mutableBytes;uint32_t *index=indices.mutableBytes;
    for (size_t i=0;i<mesh->residualCount;i++) {
        ROBSurfaceSample s=mesh->residuals[i];v[i]=(Vertex){(float)s.point.x,(float)s.point.y,(float)s.point.z};
        c[i]=(Color){((s.rgba>>24)&255)/255.f,((s.rgba>>16)&255)/255.f,((s.rgba>>8)&255)/255.f,1};index[i]=(uint32_t)i;
    }
    SCNGeometrySource *vertices=[SCNGeometrySource geometrySourceWithData:positions semantic:SCNGeometrySourceSemanticVertex
        vectorCount:mesh->residualCount floatComponents:YES componentsPerVector:3 bytesPerComponent:sizeof(float) dataOffset:0 dataStride:sizeof(Vertex)];
    SCNGeometrySource *rgb=[SCNGeometrySource geometrySourceWithData:colors semantic:SCNGeometrySourceSemanticColor
        vectorCount:mesh->residualCount floatComponents:YES componentsPerVector:4 bytesPerComponent:sizeof(float) dataOffset:0 dataStride:sizeof(Color)];
    SCNGeometryElement *element=[SCNGeometryElement geometryElementWithData:indices primitiveType:SCNGeometryPrimitiveTypePoint
        primitiveCount:mesh->residualCount bytesPerIndex:sizeof(uint32_t)];
    element.pointSize=2;element.minimumPointScreenSpaceRadius=1;element.maximumPointScreenSpaceRadius=3;
    SCNGeometry *geometry=[SCNGeometry geometryWithSources:@[vertices,rgb] elements:@[element]];
    SCNMaterial *material=[SCNMaterial material];material.lightingModelName=SCNLightingModelConstant;geometry.firstMaterial=material;return geometry;
}
static inline SCNNode *ROBSurfaceMeshNode(const ROBSurfaceMesh *mesh) {
    SCNNode *root=[SCNNode node];root.name=@"Accumulated observed surfaces · provisional display submap";
    for (size_t i=0;i<mesh->planeCount;i++) {
        SCNGeometry *geometry=ROBSurfacePlaneGeometry(&mesh->planes[i]);if (!geometry) continue;
        SCNNode *node=[SCNNode nodeWithGeometry:geometry];
        node.name=[NSString stringWithFormat:@"Observed plane %zu · %.1f mm RMS",i+1,mesh->planes[i].rms*1000];[root addChildNode:node];
    }
    SCNGeometry *residuals=ROBSurfaceResidualGeometry(mesh);
    if (residuals) { SCNNode *node=[SCNNode nodeWithGeometry:residuals];node.name=@"Observed irregular surface voxels";[root addChildNode:node]; }
    for (size_t i=0;i<mesh->cylinderCount;i++) {
        ROBSurfaceCylinder c=mesh->cylinders[i];SCNCylinder *geometry=[SCNCylinder cylinderWithRadius:c.radius height:c.height];
        geometry.radialSegmentCount=24;
        SCNMaterial *material=[SCNMaterial material];material.diffuse.contents=NSColor.systemCyanColor;
        material.lightingModelName=SCNLightingModelConstant;material.transparency=.23;material.writesToDepthBuffer=NO;material.doubleSided=YES;
        geometry.firstMaterial=material;SCNNode *node=[SCNNode nodeWithGeometry:geometry];
        node.position=SCNVector3Make(c.center.x,c.center.y,c.center.z);node.name=@"Inferred can-sized cylinder · unseen surface is a prior";
        [root addChildNode:node];
    }
    return root;
}

/* Instances are confined to the serial cloud worker; resetting the UI drops
 * its reference. An in-flight job retains its own instance until it finishes. */
@interface ROBSurfaceAccumulator : NSObject
@property(nonatomic, readonly) NSUInteger voxelCount;
- (SCNNode *)accumulate:(NSData *)samples view:(ROBSurfaceDepthView)view capturedAt:(double)capturedAt
               sequence:(uint64_t)sequence summary:(NSString **)summary;
@end
#endif
