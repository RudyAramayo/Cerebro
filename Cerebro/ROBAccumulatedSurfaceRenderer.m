#import "ROBAccumulatedSurfaceRenderer.h"

@implementation ROBSurfaceAccumulator {
    ROBSurfaceMap *_map;
    uint64_t _lastSequence;
}

- (instancetype)init
{
    if ((self=[super init])) _map=ROBSurfaceMapCreate();
    return self;
}

- (void)dealloc { ROBSurfaceMapDestroy(_map); }
- (NSUInteger)voxelCount { return _map ? _map->count : 0; }

- (SCNNode *)accumulate:(NSData *)samples view:(ROBSurfaceDepthView)view capturedAt:(double)capturedAt
               sequence:(uint64_t)sequence summary:(NSString **)summary
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
    if (summary) *summary=[NSString stringWithFormat:@"%llu frames · %zu stable voxels → %zu planes / %zu triangles + %zu points · %zu inferred cans%@",
        (unsigned long long)_map->frame,mesh->stableVoxelCount,mesh->planeCount,mesh->quadCount*2,mesh->residualCount,mesh->cylinderCount,
        mesh->truncated ? @" · detail limit reached" : @""];
    ROBSurfaceMeshDestroy(mesh);
    return node;
}
@end
