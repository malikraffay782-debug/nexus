"""Golden checks for soft/NDC visibility helpers (shared with Dart tests)."""
from __future__ import annotations

import json
import math
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
GOLDEN = ROOT / "golden" / "projection.json"
SCENE_DRAW = ROOT.parent / "assets" / "runtime" / "scene_draw.py"


class ProjectionGoldenTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.data = json.loads(GOLDEN.read_text(encoding="utf-8"))
        # Load pure helpers from scene_draw without executing draw path.
        import importlib.util

        spec = importlib.util.spec_from_file_location("scene_draw", SCENE_DRAW)
        mod = importlib.util.module_from_spec(spec)
        assert spec.loader is not None
        spec.loader.exec_module(mod)
        cls.sd = mod
        assert getattr(mod, "SCENE_DRAW_VERSION", 0) >= 2

    def test_cases(self):
        cam = self.data["camera"]
        stage = self.data["stage"]
        params = (
            float(cam["cx"]),
            float(cam["cy"]),
            float(cam["cz"]),
            float(cam["fov"]),
            float(cam["near"]),
            float(cam["far"]),
        )
        w = float(stage["width"])
        h = float(stage["height"])
        for case in self.data["cases"]:
            with self.subTest(case["name"]):
                node = {
                    "x": case["x"] - 1,
                    "y": case["y"] - 1,
                    "w": 2,
                    "h": 2,
                    "z": case["z"],
                    "type": "sprite",
                }
                vis = self.sd._visible_node(node, w, h, params, case["mode"])
                self.assertEqual(vis, case["expect_visible"], case["name"])


if __name__ == "__main__":
    unittest.main()
