"""Conservative rigid-scan self-clearance, including the swept joint path."""
import hashlib
import itertools
import json
import math

import numpy as np
from pydrake.geometry import (Convex, FramePoseVector, GeometryFrame, GeometryInstance,
                             ProximityProperties, SceneGraph)
from pydrake.math import RigidTransform


class ScanClearance:
    margin = .025
    sweep_cover = .004

    def __init__(self, planner, directory, root):
        self.planner = planner
        path = directory / "surfaces.json"
        if hashlib.sha256(path.read_bytes()).hexdigest() != planner.reference["surfacesSHA256"]:
            raise ValueError("Scan surface hash mismatch")
        document = json.loads(path.read_text())
        if document["modelID"] != planner.reference["modelID"] or document["referenceID"] != planner.reference["referenceID"]:
            raise ValueError("Scan surfaces belong to another calibration")
        self.surfaces = document["surfaces"]
        self.graph = SceneGraph()
        self.source = self.graph.RegisterSource("approved-rigid-scan")
        self.frames, self.geometry, self.boxes, self.levers = {}, {}, {}, {}
        parents = {j.find("child").get("link"): j for j in root.findall("joint")}
        # Collapse fixed mount/tool chains. Only directly connected rigid
        # assemblies are exempt; no observed overlap is automatically ignored.
        def assembly(link):
            while link in parents and parents[link].get("type") == "fixed":
                link = parents[link].find("parent").get("link")
            return link
        neighbors = {frozenset((assembly(j.find("parent").get("link")), assembly(j.find("child").get("link"))))
                     for j in root.findall("joint")}
        for surface in self.surfaces:
            name = surface["link"]
            path = directory / surface["hull"]
            if hashlib.sha256(path.read_bytes()).hexdigest() != surface["hullSHA256"]:
                raise ValueError("Collision hull hash mismatch: " + name)
            frame = self.graph.RegisterFrame(self.source, GeometryFrame(name))
            geometry = self.graph.RegisterGeometry(self.source, frame, GeometryInstance(RigidTransform(), Convex(str(path)), name))
            self.graph.AssignRole(self.source, geometry, ProximityProperties())
            self.frames[name], self.geometry[name] = frame, geometry
            # Parse all hull vertices, not the smaller vision sample set.
            points = np.array([[float(x) for x in line.split()[1:]] for line in path.read_text().splitlines() if line.startswith("v ")])
            self.boxes[name] = np.array(list(itertools.product(*zip(points.min(axis=0), points.max(axis=0)))))
            levers, link, radius = {}, name, surface["radius"]
            while link in parents:
                joint = parents[link]
                if joint.get("name") in planner.joints:
                    levers[planner.joints[joint.get("name")].position_start()] = radius
                radius += np.linalg.norm([float(x) for x in joint.find("origin").get("xyz", "0 0 0").split()])
                link = joint.find("parent").get("link")
            self.levers[name] = levers
        names = list(self.frames)
        self.pairs = [(a, b) for a, b in itertools.combinations(names, 2)
                      if assembly(a) != assembly(b) and frozenset((assembly(a), assembly(b))) not in neighbors
                      and (self.is_arm(a) or self.is_arm(b))]
        self.context = self.graph.CreateDefaultContext()

    @staticmethod
    def is_arm(name):
        return name.startswith(("left_", "right_")) and (name.endswith("_Link") or name.endswith("_tool"))

    def check(self, q, padding=0, pairs=None):
        p = self.planner
        p.plant.SetPositions(p.context, q)
        poses, boxes = FramePoseVector(), {}
        for name, frame in self.frames.items():
            transform = p.plant.CalcRelativeTransform(p.context, p.plant.world_frame(), p.plant.GetFrameByName(name, p.model))
            poses.set_value(frame, transform)
            points = transform @ self.boxes[name].T
            boxes[name] = (points.min(axis=1), points.max(axis=1))
        self.graph.get_source_pose_port(self.source).FixValue(self.context, poses)
        query = self.graph.get_query_output_port().Eval(self.context)
        minimum, nearest = math.inf, None
        required = self.margin + padding
        for a, b in (self.pairs if pairs is None else pairs):
            # Euclidean AABB distance is a lower bound, including for long links.
            separation = np.maximum(0, np.maximum(boxes[a][0] - boxes[b][1], boxes[b][0] - boxes[a][1]))
            if np.linalg.norm(separation) > max(required, .08):
                continue
            distance = float(query.ComputeSignedDistancePairClosestPoints(self.geometry[a], self.geometry[b]).distance)
            if not math.isfinite(distance):
                raise ValueError("Non-finite collision query")
            if distance < minimum:
                minimum, nearest = distance, [a, b]
        return dict(clear=minimum >= required, distance=None if not math.isfinite(minimum) else minimum,
                    pair=nearest, required=required)

    def transition(self, before, after):
        moving = set(np.flatnonzero(np.abs(after - before) > 1e-12))
        pairs = [(a, b) for a, b in self.pairs if moving.intersection(set(self.levers[a]) | set(self.levers[b]))]
        # Bound point travel relative to each pair. Shared ancestor motion
        # preserves distance and is excluded from the relative speed bound.
        travel = max((sum(abs(after[i] - before[i]) * max(self.levers[a].get(i, 0), self.levers[b].get(i, 0))
                          for i in moving if not (i in self.levers[a] and i in self.levers[b]))
                      for a, b in pairs), default=0)
        count = max(1, math.ceil(travel / (2 * self.sweep_cover)))
        if count > 500:
            return dict(clear=False, distance=None, pair=None, required=self.margin, reason="Sweep budget exceeded")
        nearest = None
        # Include both endpoints; midpoint inflation bounds the unsampled path.
        for u, padding in [(0, 0), (1, 0)] + [((i + .5) / count, travel / (2 * count)) for i in range(count)]:
            result = self.check(before + u * (after - before), padding, pairs)
            if not result["clear"]:
                return result
            if nearest is None or (result["distance"] is not None and result["distance"] < (nearest["distance"] or math.inf)):
                nearest = result
        return nearest
