#!/usr/bin/env python3
"""Exercise the general game project using actual gray-board images."""
import importlib.util
import json
from pathlib import Path
import tempfile
import uuid
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("game_study", ROOT / "Scripts/game-study.py")
study = importlib.util.module_from_spec(spec)
spec.loader.exec_module(study)


def rejects(function):
    try:
        function()
    except (ValueError, OSError):
        return
    raise AssertionError("Invalid operation was accepted")


with tempfile.TemporaryDirectory(prefix="rob-game-study-") as temporary:
    work = Path(temporary)
    project = work / "marble-chess"
    study.create(project, "Maker Faire marble board", 8, 8, [], "chess", "Chess; operator confirms all labels.")
    calibration = {"revision": str(uuid.uuid4()), "corners": [[.1, .1], [.9, .1], [.9, .9], [.1, .9]]}
    study.write_json(project / "board.json", calibration)
    labels = json.loads((project / "labels-to-review.json").read_text())
    assert labels["e1"] == "white_king" and labels["d8"] == "black_queen"
    captures = []
    for name in ("starting", "e2e4"):
        capture = work / name
        capture.mkdir()
        Image.open(ROOT / f"build/chess-study-fixtures/{name}.png").convert("RGB").save(capture / "rgb.jpg", quality=95)
        study.write_json(capture / "frame.json", {"frameID": str(uuid.uuid4()), "width": 640, "height": 640, "hasAlignedDepth": False})
        captures.append(capture)
    rejects(lambda: study.teach(project, captures[0], labels, False, "not reviewed"))
    assert study.read_project(project)["records"] == []
    study.teach(project, captures[0], labels, True, "standard setup")
    result = study.analyze(project, captures[1])
    assert set(result["changedSquares"]) == {"e2", "e4"}, result
    assert result["unknownSquares"] > 0, "identical fixture pieces must remain ambiguous"
    assert len(study.read_project(project)["records"]) == 1, "analysis must not learn predictions"
    rejects(lambda: study.teach(project, captures[1], {"e4": "white_pawn"}, True, "incomplete"))
    study.teach(project, captures[0], labels, True, "re-reviewed; supersedes prior appearance")
    assert len(study.current_records(project, study.read_project(project))) == 1
    assert len(study.read_project(project)["records"]) == 2, "correction audit must be preserved"
    rejects(lambda: study.homography([[.1, .1], [.9, .9], [.9, .1], [.1, .9]]))
    custom = work / "new-game"
    created = study.create(custom, "New token game", 4, 6, ["empty", "red_token", "blue_token"], "custom", "Rules to be demonstrated.")
    assert len(list(study.cells(created))) == 24
    assert created["motionAuthority"] == "none" and created["rulesStatus"] == "provided_not_executable"
    first_record = project / "records" / study.read_project(project)["records"][0]
    (first_record / "source.jpg").write_bytes(b"corrupt")
    rejects(lambda: study.current_records(project, study.read_project(project)))
print("General game fixtures passed: gray-board changes, unknowns, review gate, correction history, custom board and tamper rejection.")
