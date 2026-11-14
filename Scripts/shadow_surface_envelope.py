"""Build convex topology in the exact coordinate domain written to OBJ."""
import hashlib

import numpy as np
from scipy.spatial import ConvexHull


def serialized_convex_envelope(points):
    points = np.asarray(points, dtype=float)
    if points.ndim != 2 or points.shape[1] != 3 or len(points) < 4 or not np.isfinite(points).all():
        raise ValueError("A surface envelope needs finite three-dimensional source vertices")
    # Triangulating unrounded points and subsequently rounding their vertices
    # can turn an almost-coplanar face inward. Triangulate the exact values the
    # consumer will parse instead; do not relax its convexity tolerance.
    source_lines = ["v %.9f %.9f %.9f\n" % tuple(point) for point in points]
    serialized = np.asarray([[float(value) for value in line.split()[1:]] for line in source_lines])
    hull = ConvexHull(serialized)
    vertices, inverse = np.unique(hull.simplices, return_inverse=True)
    mesh = "".join(source_lines[index] for index in vertices)
    mesh += "".join("f %d %d %d\n" % tuple(face + 1) for face in inverse.reshape(-1, 3))
    planes, offsets = hull.equations[:, :3], hull.equations[:, 3]
    serialized_outside = float(np.max(np.einsum("ij,kj->ik", serialized, planes) + offsets))
    original_outside = float(np.max(np.einsum("ij,kj->ik", points, planes) + offsets))
    if not np.isfinite(serialized_outside) or serialized_outside > 1e-10:
        raise ValueError("The derived envelope does not contain every serialized source vertex")
    provenance = dict(
        schemaVersion=1,
        method="convex_hull_of_serialized_vertices_v1",
        coordinateSerializationDecimals=9,
        sourceVertexCount=len(points),
        sourceVertexLinesSHA256=hashlib.sha256("".join(source_lines).encode()).hexdigest(),
        envelopeVertexCount=len(vertices),
        envelopeFaceCount=len(hull.simplices),
        maximumSerializedSourceOutsideMeters=serialized_outside,
        maximumUnserializedSourceOutsideMeters=original_outside,
        maximumSerializationDisplacementMeters=float(np.max(np.linalg.norm(points - serialized, axis=1))),
    )
    return mesh, provenance
