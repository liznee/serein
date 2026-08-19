"""Build the original Serein studio scene in Blender and export it for the site.

The model intentionally uses only primitive meshes, curves and materials made here;
no downloaded furniture, textures, HDRIs or generated 3D assets are used.

Run with:
  blender --background --python tools/blender/create_serein_studio.py -- OUT.glb PREVIEW.png OUT.blend
"""

from __future__ import annotations

import math
import random
import sys
from pathlib import Path

import bpy
from mathutils import Vector


def args_after_double_dash() -> list[str]:
    return sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else []


ARGS = args_after_double_dash()
if len(ARGS) != 3:
    raise SystemExit("Expected: OUTPUT_GLB PREVIEW_PNG OUTPUT_BLEND")

OUTPUT_GLB, PREVIEW_PNG, OUTPUT_BLEND = (Path(value).resolve() for value in ARGS)
for output_path in (OUTPUT_GLB, PREVIEW_PNG, OUTPUT_BLEND):
    output_path.parent.mkdir(parents=True, exist_ok=True)


CORAL = (0.78, 0.20, 0.12, 1.0)
PEACH = (0.94, 0.48, 0.34, 1.0)
ROSE = (0.82, 0.35, 0.23, 1.0)
CREAM = (0.98, 0.91, 0.86, 1.0)
INK = (0.01, 0.02, 0.06, 1.0)
PANEL = (0.035, 0.065, 0.13, 1.0)
PANEL_LIT = (0.12, 0.18, 0.32, 1.0)
WALL = (0.68, 0.48, 0.42, 1.0)
FLOOR = (0.40, 0.28, 0.25, 1.0)
RUG = (0.17, 0.08, 0.07, 1.0)
METAL = (0.29, 0.17, 0.16, 1.0)
# Keep living foliage recognisably green. Accent coral belongs on the room and
# UI, not on the leaves.
GREEN = (0.075, 0.34, 0.16, 1.0)
GREEN_LIGHT = (0.18, 0.52, 0.25, 1.0)
BLUE = (0.78, 0.19, 0.12, 1.0)


def reset_scene() -> None:
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)
    for datablocks in (bpy.data.materials, bpy.data.curves, bpy.data.meshes):
        for datablock in list(datablocks):
            if datablock.users == 0:
                datablocks.remove(datablock)


def assign_material(obj: bpy.types.Object, material: bpy.types.Material) -> None:
    if not obj.data.materials:
        obj.data.materials.append(material)
    else:
        obj.data.materials[0] = material


def make_material(
    name: str,
    color: tuple[float, float, float, float],
    roughness: float = 0.48,
    metallic: float = 0.0,
    emission: float = 0.0,
) -> bpy.types.Material:
    material = bpy.data.materials.new(name)
    material.diffuse_color = color
    material.use_nodes = True
    principled = material.node_tree.nodes.get("Principled BSDF")
    if principled:
        base_color = principled.inputs.get("Base Color")
        if base_color:
            base_color.default_value = color
        metallic_input = principled.inputs.get("Metallic")
        if metallic_input:
            metallic_input.default_value = metallic
        roughness_input = principled.inputs.get("Roughness")
        if roughness_input:
            roughness_input.default_value = roughness
        emission_color = principled.inputs.get("Emission Color") or principled.inputs.get("Emission")
        if emission_color:
            emission_color.default_value = color
        emission_strength = principled.inputs.get("Emission Strength")
        if emission_strength:
            emission_strength.default_value = emission
    return material


def smooth(obj: bpy.types.Object) -> None:
    if hasattr(obj.data, "polygons"):
        for polygon in obj.data.polygons:
            polygon.use_smooth = True


def rounded_box(
    name: str,
    size: tuple[float, float, float],
    location: tuple[float, float, float],
    material: bpy.types.Material,
    bevel: float = 0.08,
    rotation: tuple[float, float, float] = (0.0, 0.0, 0.0),
) -> bpy.types.Object:
    bpy.ops.mesh.primitive_cube_add(location=location, rotation=rotation)
    obj = bpy.context.active_object
    obj.name = name
    obj.dimensions = size
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    assign_material(obj, material)
    if bevel:
        modifier = obj.modifiers.new("Soft industrial edges", "BEVEL")
        modifier.width = min(bevel, min(size) * 0.45)
        modifier.segments = 4
        modifier.limit_method = "ANGLE"
        bpy.context.view_layer.objects.active = obj
        bpy.ops.object.modifier_apply(modifier=modifier.name)
    return obj


def irregular_wall(
    name: str,
    outline: list[tuple[float, float]],
    y: float,
    depth: float,
    material: bpy.types.Material,
) -> bpy.types.Object:
    """Create one extruded X/Z wall silhouette with intentionally uneven edges."""
    front_y = y - depth * 0.5
    back_y = y + depth * 0.5
    vertices = [(x, front_y, z) for x, z in outline] + [(x, back_y, z) for x, z in outline]
    count = len(outline)
    faces = [list(range(count)), list(range(count * 2 - 1, count - 1, -1))]
    faces.extend(
        [[index, (index + 1) % count, (index + 1) % count + count, index + count] for index in range(count)]
    )
    mesh = bpy.data.meshes.new(f"{name} mesh")
    mesh.from_pydata(vertices, [], faces)
    mesh.update()
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.collection.objects.link(obj)
    assign_material(obj, material)
    bevel = obj.modifiers.new("Soft sculpted edge", "BEVEL")
    bevel.width = 0.075
    bevel.segments = 3
    bpy.context.view_layer.objects.active = obj
    bpy.ops.object.modifier_apply(modifier=bevel.name)
    return obj


def irregular_side_wall(
    name: str,
    outline: list[tuple[float, float]],
    x: float,
    depth: float,
    material: bpy.types.Material,
) -> bpy.types.Object:
    """Create an extruded Y/Z wall silhouette for the left-side cutaway wall."""
    left_x = x - depth * 0.5
    right_x = x + depth * 0.5
    vertices = [(left_x, y, z) for y, z in outline] + [(right_x, y, z) for y, z in outline]
    count = len(outline)
    faces = [list(range(count)), list(range(count * 2 - 1, count - 1, -1))]
    faces.extend(
        [[index, (index + 1) % count, (index + 1) % count + count, index + count] for index in range(count)]
    )
    mesh = bpy.data.meshes.new(f"{name} mesh")
    mesh.from_pydata(vertices, [], faces)
    mesh.update()
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.collection.objects.link(obj)
    assign_material(obj, material)
    bevel = obj.modifiers.new("Block-edge softening", "BEVEL")
    bevel.width = 0.06
    bevel.segments = 2
    bpy.context.view_layer.objects.active = obj
    bpy.ops.object.modifier_apply(modifier=bevel.name)
    return obj


def irregular_floor(
    name: str,
    outline: list[tuple[float, float]],
    z: float,
    height: float,
    material: bpy.types.Material,
) -> bpy.types.Object:
    """Create a low stage with a rectilinear, stepped perimeter."""
    bottom_z = z - height * 0.5
    top_z = z + height * 0.5
    vertices = [(x, y, bottom_z) for x, y in outline] + [(x, y, top_z) for x, y in outline]
    count = len(outline)
    faces = [list(range(count)), list(range(count * 2 - 1, count - 1, -1))]
    faces.extend(
        [[index, (index + 1) % count, (index + 1) % count + count, index + count] for index in range(count)]
    )
    mesh = bpy.data.meshes.new(f"{name} mesh")
    mesh.from_pydata(vertices, [], faces)
    mesh.update()
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.collection.objects.link(obj)
    assign_material(obj, material)
    bevel = obj.modifiers.new("Stepped perimeter edge", "BEVEL")
    bevel.width = 0.055
    bevel.segments = 2
    bpy.context.view_layer.objects.active = obj
    bpy.ops.object.modifier_apply(modifier=bevel.name)
    return obj


def cylinder(
    name: str,
    radius: float,
    depth: float,
    location: tuple[float, float, float],
    material: bpy.types.Material,
    rotation: tuple[float, float, float] = (0.0, 0.0, 0.0),
    vertices: int = 48,
) -> bpy.types.Object:
    bpy.ops.mesh.primitive_cylinder_add(
        vertices=vertices, radius=radius, depth=depth, location=location, rotation=rotation
    )
    obj = bpy.context.active_object
    obj.name = name
    assign_material(obj, material)
    smooth(obj)
    bevel = obj.modifiers.new("Edge rounding", "BEVEL")
    bevel.width = min(radius * 0.18, 0.045)
    bevel.segments = 3
    bpy.context.view_layer.objects.active = obj
    bpy.ops.object.modifier_apply(modifier=bevel.name)
    return obj


def uv_sphere(
    name: str,
    location: tuple[float, float, float],
    scale: tuple[float, float, float],
    material: bpy.types.Material,
) -> bpy.types.Object:
    bpy.ops.mesh.primitive_uv_sphere_add(segments=40, ring_count=20, location=location)
    obj = bpy.context.active_object
    obj.name = name
    obj.scale = scale
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    assign_material(obj, material)
    smooth(obj)
    return obj


def torus(
    name: str,
    major: float,
    minor: float,
    location: tuple[float, float, float],
    material: bpy.types.Material,
    rotation: tuple[float, float, float] = (0.0, 0.0, 0.0),
) -> bpy.types.Object:
    bpy.ops.mesh.primitive_torus_add(
        major_radius=major,
        minor_radius=minor,
        major_segments=56,
        minor_segments=12,
        location=location,
        rotation=rotation,
    )
    obj = bpy.context.active_object
    obj.name = name
    assign_material(obj, material)
    smooth(obj)
    return obj


def pipe(
    name: str,
    points: list[tuple[float, float, float]],
    radius: float,
    material: bpy.types.Material,
) -> bpy.types.Object:
    curve = bpy.data.curves.new(name, "CURVE")
    curve.dimensions = "3D"
    curve.resolution_u = 16
    curve.bevel_depth = radius
    curve.bevel_resolution = 4
    spline = curve.splines.new("BEZIER")
    spline.bezier_points.add(len(points) - 1)
    for point, coordinate in zip(spline.bezier_points, points):
        point.co = coordinate
        point.handle_left_type = "AUTO"
        point.handle_right_type = "AUTO"
    obj = bpy.data.objects.new(name, curve)
    bpy.context.collection.objects.link(obj)
    assign_material(obj, material)
    return obj


def text_mesh(
    text: str,
    location: tuple[float, float, float],
    size: float,
    material: bpy.types.Material,
    rotation: tuple[float, float, float],
) -> bpy.types.Object:
    bpy.ops.object.text_add(location=location, rotation=rotation)
    obj = bpy.context.active_object
    obj.name = f"Text_{text}"
    obj.data.body = text
    obj.data.align_x = "CENTER"
    obj.data.align_y = "CENTER"
    obj.data.size = size
    obj.data.extrude = 0.025
    obj.data.bevel_depth = 0.007
    assign_material(obj, material)
    bpy.context.view_layer.objects.active = obj
    obj.select_set(True)
    bpy.ops.object.convert(target="MESH")
    return bpy.context.active_object


def look_at(obj: bpy.types.Object, target: tuple[float, float, float]) -> None:
    direction = Vector(target) - obj.location
    obj.rotation_euler = direction.to_track_quat("-Z", "Y").to_euler()


def create_gem(location: tuple[float, float, float], scale: float, material: bpy.types.Material) -> None:
    bpy.ops.mesh.primitive_ico_sphere_add(subdivisions=1, radius=scale, location=location)
    gem = bpy.context.active_object
    gem.name = "Serein coral crystal"
    gem.scale = (1.08, 0.68, 0.9)
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    assign_material(gem, material)
    bevel = gem.modifiers.new("Gem edge glint", "BEVEL")
    bevel.width = scale * 0.045
    bevel.segments = 2
    bpy.context.view_layer.objects.active = gem
    bpy.ops.object.modifier_apply(modifier=bevel.name)


def add_ficus(origin: tuple[float, float, float], scale: float, pot_material, leaf_material) -> None:
    """Add an upright broad-leaf ficus, rather than a radial cactus shape."""
    x, y, z = origin
    cylinder("Planter pot", 0.28 * scale, 0.42 * scale, (x, y, z + 0.21 * scale), pot_material)
    torus("Planter rim", 0.28 * scale, 0.035 * scale, (x, y, z + 0.43 * scale), PEACH_MAT)
    cylinder("Planter soil", 0.225 * scale, 0.028 * scale, (x, y, z + 0.44 * scale), RUG_MAT)
    for index, angle in enumerate((10, 52, 95, 138, 186, 226, 272, 318, 344)):
        radians = math.radians(angle)
        height = (0.76 + (index % 3) * 0.15) * scale
        spread = (0.12 + (index % 4) * 0.035) * scale
        leaf_x = x + math.cos(radians) * spread
        leaf_y = y + math.sin(radians) * spread
        leaf_z = z + height
        pipe(
            f"Ficus stem {index}",
            [(x, y, z + 0.45 * scale), (leaf_x * 0.35 + x * 0.65, leaf_y * 0.35 + y * 0.65, leaf_z * 0.72), (leaf_x, leaf_y, leaf_z)],
            0.016 * scale,
            METAL_MAT,
        )
        leaf = uv_sphere(
            f"Ficus leaf {index}",
            (leaf_x, leaf_y, leaf_z),
            (0.29 * scale, 0.075 * scale, 0.17 * scale),
            GREEN_LIGHT_MAT if index % 3 == 0 else leaf_material,
        )
        leaf.rotation_euler = (
            math.radians(38) + math.radians(12) * math.cos(radians),
            math.radians(18) * math.sin(radians),
            radians,
        )


reset_scene()
random.seed(20260726)

INK_MAT = make_material("Ink", INK, 0.34, 0.2)
PANEL_MAT = make_material("Blue black panel", PANEL, 0.36, 0.32)
PANEL_LIT_MAT = make_material("Lit panel", PANEL_LIT, 0.42, 0.15)
WALL_MAT = make_material("Warm graphite wall", WALL, 0.42, 0.12)
FLOOR_MAT = make_material("Warm architectural floor", FLOOR, 0.48, 0.08)
RUG_MAT = make_material("Woven warm rug", RUG, 0.72, 0.0)
METAL_MAT = make_material("Warm metal", METAL, 0.26, 0.76)
CORAL_MAT = make_material("Serein coral", CORAL, 0.31, 0.32)
PEACH_MAT = make_material("Serein peach light", PEACH, 0.26, 0.2, 1.8)
ROSE_MAT = make_material("Serein rose", ROSE, 0.32, 0.28)
CREAM_MAT = make_material("Warm cream", CREAM, 0.42, 0.05)
# Keep the sleeping Shiba matte rather than emissive: the general peach material
# is intentionally lit for UI accents, which made the dog read as white.
SHIBA_MAT = make_material("Shiba coat", (0.72, 0.19, 0.07, 1.0), 0.58, 0.0)
GREEN_MAT = make_material("Foliage", GREEN, 0.65, 0.0)
GREEN_LIGHT_MAT = make_material("Foliage highlight", GREEN_LIGHT, 0.62, 0.0)
BLUE_MAT = make_material("Interface blue", BLUE, 0.42, 0.1, 0.2)
SCREEN_MAT = make_material("Screen placeholder", (0.005, 0.008, 0.014, 1.0), 0.2, 0.0, 0.08)

# Floating architectural stage: an open, cinematic cutaway without a visible frame.
irregular_floor(
    "Studio plinth",
    [
        (-8.10, -4.06), (-6.58, -4.06), (-6.58, -4.48), (-4.34, -4.48),
        (-4.34, -4.12), (-1.58, -4.12), (-1.58, -4.62), (1.22, -4.62),
        (1.22, -4.18), (4.10, -4.18), (4.10, -4.54), (6.18, -4.54),
        (6.18, -4.12), (7.84, -4.12), (7.84, -2.52), (8.26, -2.52),
        (8.26, -0.64), (7.88, -0.64), (7.88, 1.10), (8.30, 1.10),
        (8.30, 3.08), (7.84, 3.08), (7.84, 4.46), (5.86, 4.46),
        (5.86, 4.84), (3.48, 4.84), (3.48, 4.42), (0.94, 4.42),
        (0.94, 4.98), (-1.48, 4.98), (-1.48, 4.42), (-3.72, 4.42),
        (-3.72, 4.82), (-5.72, 4.82), (-5.72, 4.40), (-8.06, 4.40),
        (-8.06, 2.46), (-8.46, 2.46), (-8.46, 0.44), (-8.04, 0.44),
        (-8.04, -1.48), (-8.40, -1.48), (-8.40, -3.30), (-8.10, -3.30),
    ],
    -0.26,
    0.48,
    PANEL_MAT,
)
irregular_floor(
    "Plinth inset",
    [
        (-7.78, -3.74), (-7.12, -3.74), (-7.12, -4.02), (-6.30, -4.02),
        (-6.30, -3.78), (-5.18, -3.78), (-5.18, -4.16), (-4.30, -4.16),
        (-4.30, -3.76), (-3.05, -3.76), (-3.05, -4.10), (-1.76, -4.10),
        (-1.76, -3.80), (-0.72, -3.80), (-0.72, -4.22), (0.54, -4.22),
        (0.54, -3.82), (1.72, -3.82), (1.72, -4.14), (2.92, -4.14),
        (2.92, -3.76), (4.14, -3.76), (4.14, -4.06), (5.36, -4.06),
        (5.36, -3.74), (6.62, -3.74), (6.62, -3.36), (7.62, -3.36),
        (7.62, -2.50), (7.32, -2.50), (7.32, -1.56), (7.66, -1.56),
        (7.66, -0.48), (7.34, -0.48), (7.34, 0.58), (7.70, 0.58),
        (7.70, 1.56), (7.32, 1.56), (7.32, 2.46), (7.62, 2.46),
        (7.62, 3.42), (6.54, 3.42), (6.54, 3.82), (5.34, 3.82),
        (5.34, 3.52), (4.06, 3.52), (4.06, 3.90), (2.84, 3.90),
        (2.84, 3.56), (1.58, 3.56), (1.58, 3.96), (0.36, 3.96),
        (0.36, 3.56), (-0.94, 3.56), (-0.94, 3.90), (-2.04, 3.90),
        (-2.04, 3.56), (-3.20, 3.56), (-3.20, 3.96), (-4.36, 3.96),
        (-4.36, 3.54), (-5.48, 3.54), (-5.48, 3.88), (-6.74, 3.88),
        (-6.74, 3.48), (-7.82, 3.48), (-7.82, 2.54), (-7.50, 2.54),
        (-7.50, 1.50), (-7.86, 1.50), (-7.86, 0.54), (-7.50, 0.54),
        (-7.50, -0.50), (-7.84, -0.50), (-7.84, -1.58), (-7.48, -1.58),
        (-7.48, -2.70), (-7.78, -2.70),
    ],
    0.05,
    0.15,
    INK_MAT,
)
# Three irregular wall planes overlap at different depths, avoiding a rigid box-room silhouette.
irregular_wall(
    "Back wall left extension",
    [
        (-7.92, 0.34), (-7.92, 3.76), (-6.82, 3.76), (-6.82, 5.92),
        (-5.12, 5.92), (-5.12, 5.14), (-4.02, 5.14), (-4.02, 6.88),
        (-2.86, 6.88), (-2.86, 0.34),
    ],
    4.10,
    0.28,
    WALL_MAT,
)
irregular_wall(
    "Back wall centre extension",
    [
        (-2.68, 0.34), (-2.68, 6.18), (-1.18, 6.18), (-1.18, 5.22),
        (0.76, 5.22), (0.76, 7.14), (2.68, 7.14), (2.68, 0.34),
    ],
    4.28,
    0.24,
    WALL_MAT,
)
irregular_wall(
    "Back wall right extension",
    [
        (2.92, 0.34), (2.92, 5.36), (4.10, 5.36), (4.10, 6.72),
        (5.94, 6.72), (5.94, 4.76), (7.70, 4.76), (7.70, 0.34),
    ],
    4.03,
    0.30,
    WALL_MAT,
)
irregular_side_wall(
    "Left cutaway front fragment",
    [
        (-4.14, 0.28), (-4.14, 1.56), (-3.78, 1.56), (-3.78, 2.52),
        (-3.42, 2.52), (-3.42, 3.22), (-3.16, 3.22), (-3.16, 0.28),
    ],
    -5.75,
    0.34,
    PANEL_LIT_MAT,
)
irregular_side_wall(
    "Left cutaway bike fragment one",
    [
        (-2.88, 0.28), (-2.88, 3.64), (-2.58, 3.64), (-2.58, 4.48),
        (-2.14, 4.48), (-2.14, 3.92), (-1.70, 3.92), (-1.70, 4.94),
        (-1.16, 4.94), (-1.16, 0.28),
    ],
    -5.75,
    0.34,
    PANEL_LIT_MAT,
)
irregular_side_wall(
    "Left cutaway bike fragment two",
    [
        (-0.82, 0.28), (-0.82, 2.74), (-0.46, 2.74), (-0.46, 4.96),
        (-0.08, 4.96), (-0.08, 4.22), (0.34, 4.22), (0.34, 5.70),
        (0.82, 5.70), (0.82, 0.28),
    ],
    -5.75,
    0.34,
    PANEL_LIT_MAT,
)
irregular_side_wall(
    "Left cutaway rear fragment one",
    [
        (1.14, 0.28), (1.14, 4.14), (1.50, 4.14), (1.50, 6.66),
        (1.98, 6.66), (1.98, 5.18), (2.40, 5.18), (2.40, 0.28),
    ],
    -5.75,
    0.34,
    PANEL_LIT_MAT,
)
irregular_side_wall(
    "Left cutaway rear fragment two",
    [
        (2.74, 0.28), (2.74, 3.36), (3.10, 3.36), (3.10, 5.38),
        (3.54, 5.38), (3.54, 4.70), (3.94, 4.70), (3.94, 6.20),
        (4.18, 6.20), (4.18, 0.28),
    ],
    -5.75,
    0.34,
    PANEL_LIT_MAT,
)
rounded_box("Right architectural fin", (0.34, 3.12, 4.46), (7.35, 2.76, 2.28), PANEL_LIT_MAT, 0.18)

# Floor construction: a muted woven rug sits over subtle modular floor panels.
for panel_index in range(6):
    rounded_box(
        f"Floor inlay {panel_index}",
        (1.78, 6.92, 0.022),
        (-4.55 + panel_index * 1.82, 0.35, 0.145),
        FLOOR_MAT if panel_index % 2 else PANEL_LIT_MAT,
        0.035,
    )
rounded_box("Woven coral rug", (5.75, 4.15, 0.045), (0.0, -0.78, 0.18), ROSE_MAT, 0.28)
rounded_box("Woven rug inner field", (5.48, 3.88, 0.024), (0.0, -0.78, 0.212), RUG_MAT, 0.24)
for stripe_index in range(7):
    rounded_box(
        f"Rug weave stripe {stripe_index}",
        (0.22, 3.15, 0.012),
        (-0.9 + stripe_index * 0.3, -0.78, 0.23),
        ROSE_MAT if stripe_index % 2 else CORAL_MAT,
        0.012,
    )

# Dark, uneven seams make the plinth read as a repaired fragment rather than a
# perfect floating rectangle. Their widths and offsets are intentionally varied.
for break_index, (break_x, break_y, break_w, break_h) in enumerate((
    (-6.96, -3.74, 0.42, 0.24), (-5.72, -3.92, 0.68, 0.18),
    (-4.04, -3.80, 0.28, 0.42), (-2.54, -3.96, 0.76, 0.20),
    (-0.98, -3.72, 0.34, 0.36), (0.88, -3.94, 0.58, 0.18),
    (2.46, -3.76, 0.26, 0.40), (4.66, -3.84, 0.82, 0.22),
    (6.82, -2.36, 0.20, 0.64), (7.02, -0.44, 0.24, 0.36),
    (6.80, 1.46, 0.20, 0.76), (5.72, 3.66, 0.70, 0.20),
    (3.54, 3.70, 0.26, 0.48), (1.18, 3.70, 0.80, 0.20),
    (-1.40, 3.72, 0.34, 0.46), (-3.92, 3.66, 0.78, 0.20),
    (-6.20, 3.60, 0.24, 0.54), (-7.02, 1.74, 0.22, 0.68),
)):
    rounded_box(
        f"Floor repair void {break_index}",
        (break_w, break_h, 0.026),
        (break_x, break_y, 0.145),
        SCREEN_MAT,
        0.012,
    )

# The outer deck deliberately grows as mismatched blocks rather than a symmetric
# staircase: each fragment has its own reach, height and broken interval. This
# makes the silhouette feel like an expanding cutaway floor, not a castle wall.
for fragment_index, (size_x, size_y, size_z, x, y, z, material) in enumerate((
    (1.18, 0.62, 0.28, -7.88, -4.66, -0.20, PANEL_MAT),
    (0.54, 1.06, 0.18, -6.62, -4.88, -0.14, PANEL_LIT_MAT),
    (1.64, 0.44, 0.34, -5.06, -4.94, -0.31, PANEL_MAT),
    (0.76, 0.84, 0.21, -3.18, -4.78, -0.10, PANEL_LIT_MAT),
    (1.08, 0.48, 0.42, -1.36, -5.03, -0.35, PANEL_MAT),
    (0.46, 1.16, 0.24, 0.12, -4.96, -0.16, PANEL_LIT_MAT),
    (1.38, 0.52, 0.31, 1.94, -4.98, -0.25, PANEL_MAT),
    (0.68, 0.94, 0.16, 3.58, -4.72, -0.09, PANEL_LIT_MAT),
    (1.02, 0.46, 0.38, 5.34, -4.98, -0.33, PANEL_MAT),
    (0.44, 1.22, 0.22, 7.98, -3.36, -0.15, PANEL_LIT_MAT),
    (0.70, 0.54, 0.35, 8.22, -1.34, -0.29, PANEL_MAT),
    (0.46, 1.34, 0.19, 8.04, 1.26, -0.12, PANEL_LIT_MAT),
    (1.24, 0.42, 0.30, 6.62, 4.72, -0.24, PANEL_MAT),
    (0.58, 0.88, 0.17, 4.64, 4.82, -0.10, PANEL_LIT_MAT),
    (1.46, 0.48, 0.39, 2.18, 5.10, -0.34, PANEL_MAT),
    (0.52, 1.04, 0.23, -0.64, 4.86, -0.15, PANEL_LIT_MAT),
    (1.10, 0.46, 0.32, -2.84, 5.02, -0.27, PANEL_MAT),
    (0.44, 1.22, 0.18, -5.34, 4.74, -0.11, PANEL_LIT_MAT),
    (1.34, 0.50, 0.36, -7.18, 4.92, -0.30, PANEL_MAT),
    (0.48, 1.10, 0.20, -8.34, 2.88, -0.13, PANEL_LIT_MAT),
    (0.76, 0.44, 0.29, -8.62, 0.84, -0.22, PANEL_MAT),
    (0.40, 1.26, 0.16, -8.48, -1.96, -0.09, PANEL_LIT_MAT),
)):
    rounded_box(
        f"Asymmetric outer deck fragment {fragment_index}",
        (size_x, size_y, size_z),
        (x, y, z),
        material,
        0.045,
    )

# Coral tracing grooves give the scene a recognizable Serein silhouette.
pipe("Back wall light ribbon", [(-5.05, 3.83, 5.15), (-2.1, 3.83, 5.15), (-0.8, 3.83, 4.72), (2.9, 3.83, 4.72), (5.1, 3.83, 5.1)], 0.028, PEACH_MAT)
pipe("Floor light ribbon", [(-4.8, -2.8, 0.17), (-2.8, -3.08, 0.17), (0.0, -3.16, 0.17), (2.8, -3.08, 0.17), (4.8, -2.8, 0.17)], 0.032, CORAL_MAT)

# Central workstation: desk, drawers, hardware and top trim.
rounded_box("Desk top", (6.85, 2.05, 0.22), (0.05, 0.55, 2.0), CREAM_MAT, 0.16)
rounded_box("Desk front coral trim", (6.48, 0.08, 0.055), (0.05, -0.45, 1.96), CORAL_MAT, 0.025)
rounded_box("Desk left drawer tower", (1.15, 1.65, 1.78), (-2.64, 0.78, 1.08), PANEL_LIT_MAT, 0.14)
rounded_box("Desk right support", (0.75, 1.28, 1.74), (2.68, 0.72, 1.1), PANEL_LIT_MAT, 0.14)
for drawer_index, drawer_z in enumerate((1.48, 1.02, 0.56)):
    rounded_box(f"Drawer face {drawer_index}", (0.91, 0.06, 0.32), (-2.64, -0.065, drawer_z), INK_MAT, 0.045)
    rounded_box(f"Drawer pull {drawer_index}", (0.32, 0.035, 0.035), (-2.64, -0.11, drawer_z), CORAL_MAT, 0.014)
for foot_x in (-2.65, 2.68):
    cylinder("Desk foot", 0.16, 0.14, (foot_x, 0.74, 0.16), METAL_MAT)
torus("Desk cable grommet", 0.13, 0.026, (1.95, 0.82, 2.13), METAL_MAT)

# Monitor and live-video mesh. Keep the physical bezel slim and use an exact
# 16:9 surface, so the in-room video and the focused view share the same frame.
rounded_box("Monitor shell", (4.34, 0.24, 2.60), (0.15, 0.78, 3.58), METAL_MAT, 0.16)
rounded_box("Monitor bezel", (4.08, 0.07, 2.38), (0.15, 0.91, 3.58), INK_MAT, 0.10)
screen = rounded_box("SereinVideoSurface", (3.98, 0.025, 2.23875), (0.15, 0.958, 3.58), SCREEN_MAT, 0.028)
screen["serein_video_surface"] = True
rounded_box("Monitor stand", (0.34, 0.34, 0.77), (0.15, 0.97, 2.39), METAL_MAT, 0.09)
rounded_box("Monitor stand foot", (1.42, 0.72, 0.12), (0.15, 0.9, 2.08), METAL_MAT, 0.08)
uv_sphere("Webcam", (0.15, 0.965, 4.83), (0.105, 0.055, 0.07), INK_MAT)
uv_sphere("Webcam indicator", (0.22, 0.905, 4.83), (0.018, 0.012, 0.018), GREEN_LIGHT_MAT)

# Keyboard, mouse and small desk devices make the workstation feel inhabited.
rounded_box("Keyboard chassis", (2.56, 0.96, 0.11), (0.05, -0.45, 2.18), INK_MAT, 0.11)
rounded_box("Keyboard underglow", (2.42, 0.78, 0.026), (0.05, -0.45, 2.135), CORAL_MAT, 0.08)
key_colors = (PANEL_LIT_MAT, PANEL_MAT, PANEL_LIT_MAT, CORAL_MAT)
for row in range(5):
    for col in range(13):
        width = 0.125 if col not in (0, 12) else 0.18
        rounded_box(
            f"Key {row}-{col}",
            (width, 0.118, 0.05),
            (-1.02 + col * 0.17, -0.79 + row * 0.16, 2.26),
            key_colors[3] if (row, col) in ((0, 0), (1, 12), (4, 0), (4, 12)) else key_colors[(row + col) % 3],
            0.024,
        )
rounded_box("Spacebar", (0.94, 0.118, 0.05), (0.02, -0.15, 2.26), PANEL_LIT_MAT, 0.024)
rounded_box("Keyboard knob", (0.12, 0.12, 0.058), (1.02, -0.12, 2.27), PEACH_MAT, 0.045)
rounded_box("Keyboard wrist rest", (2.28, 0.24, 0.095), (0.05, -1.00, 2.2), PANEL_LIT_MAT, 0.09)
rounded_box("Mouse pad", (1.12, 1.05, 0.025), (1.88, -0.4, 2.14), PANEL_LIT_MAT, 0.14)
rounded_box("Mouse lower shell", (0.58, 0.86, 0.17), (1.83, -0.48, 2.22), PANEL_MAT, 0.20)
uv_sphere("Mouse upper shell", (1.83, -0.48, 2.33), (0.305, 0.44, 0.15), CREAM_MAT)
rounded_box("Mouse centre spine", (0.045, 0.47, 0.025), (1.83, -0.49, 2.47), CORAL_MAT, 0.018)
rounded_box("Mouse left click", (0.23, 0.30, 0.025), (1.66, -0.69, 2.455), CREAM_MAT, 0.05)
rounded_box("Mouse right click", (0.23, 0.30, 0.025), (2.00, -0.69, 2.455), CREAM_MAT, 0.05)
cylinder("Mouse scroll wheel", 0.048, 0.13, (1.83, -0.60, 2.49), BLUE_MAT, (math.radians(90), 0, 0))
rounded_box("Mouse DPI button", (0.065, 0.10, 0.028), (1.83, -0.36, 2.47), PEACH_MAT, 0.018)
rounded_box("Phone dock", (0.55, 0.18, 0.66), (-2.05, -0.15, 2.38), METAL_MAT, 0.07, (math.radians(-20), 0, 0))
rounded_box("Phone screen", (0.43, 0.026, 0.52), (-2.05, -0.25, 2.43), BLUE_MAT, 0.035, (math.radians(-20), 0, 0))

# Ergonomic chair: the seat faces the monitor (+Y); the back now sits behind it.
rounded_box("Chair seat", (1.75, 1.48, 0.24), (0.14, -2.0, 1.19), ROSE_MAT, 0.22)
rounded_box("Chair back", (1.65, 0.28, 1.74), (0.14, -2.66, 2.22), ROSE_MAT, 0.22, (math.radians(13), 0, 0))
rounded_box("Chair inner back", (1.4, 0.05, 1.42), (0.14, -2.49, 2.21), PANEL_LIT_MAT, 0.12, (math.radians(13), 0, 0))
rounded_box("Chair lumbar cushion", (0.92, 0.055, 0.43), (0.14, -2.45, 1.9), CORAL_MAT, 0.11, (math.radians(13), 0, 0))
cylinder("Chair gas lift", 0.11, 0.83, (0.14, -1.94, 0.72), METAL_MAT)
cylinder("Chair star hub", 0.18, 0.18, (0.14, -1.94, 0.27), METAL_MAT)
for index in range(5):
    angle = math.radians(index * 72 + 18)
    end_x = 0.14 + math.cos(angle) * 0.96
    end_y = -1.94 + math.sin(angle) * 0.96
    pipe(f"Chair spoke {index}", [(0.14, -1.94, 0.31), (end_x, end_y, 0.20)], 0.055, METAL_MAT)
    wheel = uv_sphere(f"Chair wheel {index}", (end_x, end_y, 0.1), (0.16, 0.09, 0.12), INK_MAT)
    wheel.rotation_euler[2] = angle
for arm_x in (-0.98, 1.26):
    pipe("Chair arm", [(arm_x * 0.64, -2.0, 1.23), (arm_x * 0.64, -1.93, 1.68), (arm_x * 0.58, -1.67, 1.7)], 0.045, METAL_MAT)
    rounded_box("Chair arm pad", (0.42, 0.62, 0.12), (arm_x * 0.58, -1.67, 1.72), INK_MAT, 0.07)

# Side shelving, books, and planted corner. It sits beside, rather than in front
# of, the doorway so the room reads clearly even from the preview camera.
rounded_box("Shelf upright left", (0.16, 0.42, 3.4), (-3.15, 3.45, 2.05), METAL_MAT, 0.055)
rounded_box("Shelf upright right", (0.16, 0.42, 3.4), (-1.34, 3.45, 2.05), METAL_MAT, 0.055)
for shelf_index, shelf_z in enumerate((0.65, 1.65, 2.65, 3.65)):
    rounded_box(f"Shelf board {shelf_index}", (2.0, 0.54, 0.11), (-2.25, 3.42, shelf_z), PANEL_LIT_MAT, 0.035)
for book_index in range(17):
    shelf_row = book_index // 6
    shelf_z = (0.87, 1.87, 2.87)[shelf_row]
    x = -2.88 + (book_index % 6) * 0.24
    book_height = 0.38 + (book_index % 3) * 0.075
    rounded_box(
        f"Shelf book {book_index}",
        (0.15, 0.27, book_height),
        (x, 3.36, shelf_z + book_height * 0.5),
        (CORAL_MAT, PEACH_MAT, ROSE_MAT, BLUE_MAT)[book_index % 4],
        0.018,
        (0.0, math.radians((book_index % 3 - 1) * 5), 0.0),
    )
add_ficus((4.55, 2.72, 0.18), 1.4, PANEL_LIT_MAT, GREEN_MAT)

# A sculptural lamp and a compact desktop PC add story without borrowed assets.
cylinder("Lamp base", 0.46, 0.11, (3.92, 1.32, 0.24), METAL_MAT)
pipe("Lamp stem", [(3.92, 1.32, 0.28), (4.04, 1.34, 2.15), (3.54, 1.13, 3.22)], 0.07, METAL_MAT)
uv_sphere("Lamp globe", (3.5, 1.1, 3.28), (0.36, 0.36, 0.36), PEACH_MAT)
rounded_box("PC tower", (0.88, 1.32, 2.2), (4.15, -0.6, 1.32), PANEL_MAT, 0.14)
rounded_box("PC glass side", (0.56, 0.025, 1.82), (3.69, -0.6, 1.34), PANEL_LIT_MAT, 0.06)
for fan_z in (0.84, 1.82):
    torus("PC fan ring", 0.21, 0.025, (3.66, -0.63, fan_z), CORAL_MAT, (math.radians(90), 0, 0))
    uv_sphere("PC fan hub", (3.66, -0.65, fan_z), (0.045, 0.025, 0.045), PEACH_MAT)

# Door, moulding and small wall details make the cutaway read as a real room.
# A warm coral surround makes it instantly legible rather than a dark wall panel.
rounded_box("Door coral surround", (2.05, 0.12, 3.70), (-4.52, 3.79, 2.05), CORAL_MAT, 0.13)
rounded_box("Door frame", (1.80, 0.13, 3.46), (-4.52, 3.72, 2.03), CREAM_MAT, 0.10)
rounded_box("Door leaf", (1.56, 0.055, 3.18), (-4.52, 3.635, 2.02), FLOOR_MAT, 0.08)
rounded_box("Door inset upper", (1.08, 0.026, 0.98), (-4.52, 3.59, 2.63), PANEL_LIT_MAT, 0.07)
rounded_box("Door inset lower", (1.08, 0.026, 0.78), (-4.52, 3.59, 1.27), PANEL_LIT_MAT, 0.07)
rounded_box("Door mail slot", (0.52, 0.025, 0.11), (-4.52, 3.57, 2.05), PEACH_MAT, 0.035)
cylinder("Door handle", 0.065, 0.24, (-3.91, 3.52, 2.05), PEACH_MAT, (math.radians(90), 0, 0))
rounded_box("Door threshold", (1.78, 0.48, 0.082), (-4.52, 3.48, 0.24), CORAL_MAT, 0.045)
text_mesh("STUDIO", (-4.52, 3.50, 3.66), 0.16, PEACH_MAT, (math.radians(90), 0, 0))
for moulding_x in (-2.05, 1.38):
    rounded_box("Wall vertical moulding", (0.06, 0.036, 5.15), (moulding_x, 3.80, 3.1), METAL_MAT, 0.02)
rounded_box("Wall baseboard", (10.96, 0.075, 0.14), (0, 3.77, 0.42), METAL_MAT, 0.03)
rounded_box("Wall shelf", (1.46, 0.34, 0.10), (1.52, 3.56, 3.84), METAL_MAT, 0.035)
for object_index, object_x in enumerate((1.08, 1.42, 1.76)):
    rounded_box(
        f"Wall shelf object {object_index}",
        (0.18, 0.16, 0.34 + object_index * 0.10),
        (object_x, 3.54, 4.08 + object_index * 0.05),
        (CORAL_MAT, PEACH_MAT, BLUE_MAT)[object_index],
        0.035,
    )

# A clearly canine, curled Shiba: fox-like triangular ears, white cheeks/chest,
# paws, collar and a curled tail make it read as a dog rather than a cat blob.
rounded_box("Shiba cushion", (1.80, 1.22, 0.10), (-3.54, -1.20, 0.28), RUG_MAT, 0.22)
uv_sphere("Shiba curled body", (-3.58, -1.30, 0.56), (0.82, 0.62, 0.40), SHIBA_MAT)
uv_sphere("Shiba white chest", (-3.58, -0.92, 0.56), (0.46, 0.14, 0.25), CREAM_MAT)
uv_sphere("Shiba sleeping head", (-3.58, -1.84, 0.78), (0.47, 0.38, 0.39), SHIBA_MAT)
uv_sphere("Shiba cream muzzle", (-3.58, -2.16, 0.67), (0.29, 0.12, 0.17), CREAM_MAT)
for ear_index, ear_x in enumerate((-3.87, -3.29)):
    bpy.ops.mesh.primitive_cone_add(vertices=3, radius1=0.18, radius2=0.045, depth=0.42, location=(ear_x, -1.87, 1.12), rotation=(math.radians(-8), 0, math.radians(180 if ear_index == 0 else 0)))
    ear = bpy.context.active_object
    ear.name = f"Shiba triangular ear {ear_index}"
    assign_material(ear, SHIBA_MAT)
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    bevel = ear.modifiers.new("Soft ear edge", "BEVEL")
    bevel.width = 0.028
    bevel.segments = 2
    bpy.context.view_layer.objects.active = ear
    bpy.ops.object.modifier_apply(modifier=bevel.name)
for paw_index, paw_x in enumerate((-3.90, -3.27)):
    uv_sphere(f"Shiba white paw {paw_index}", (paw_x, -1.91, 0.38), (0.20, 0.19, 0.11), CREAM_MAT)
uv_sphere("Shiba closed eye left", (-3.74, -2.17, 0.81), (0.07, 0.025, 0.019), INK_MAT)
uv_sphere("Shiba closed eye right", (-3.42, -2.17, 0.81), (0.07, 0.025, 0.019), INK_MAT)
uv_sphere("Shiba nose", (-3.58, -2.31, 0.70), (0.055, 0.028, 0.042), INK_MAT)
torus("Shiba collar", 0.32, 0.028, (-3.58, -1.74, 0.65), CORAL_MAT, (math.radians(90), 0, 0))
torus("Shiba curled tail", 0.34, 0.080, (-2.77, -1.03, 0.73), CREAM_MAT, (math.radians(78), 0, 0))
uv_sphere("Shiba tail coat", (-2.86, -1.34, 0.70), (0.18, 0.11, 0.20), SHIBA_MAT)

# A compact lounge corner makes the room feel like a place to stay, not a
# floating demo set. It stays behind the desk, preserving the monitor sightline.
rounded_box("Lounge sofa base", (2.30, 0.82, 0.42), (-3.38, 1.88, 0.72), PANEL_LIT_MAT, 0.16)
rounded_box("Lounge sofa cushion", (2.12, 0.70, 0.22), (-3.38, 1.82, 0.98), ROSE_MAT, 0.14)
rounded_box("Lounge sofa back", (2.28, 0.18, 1.06), (-3.38, 2.18, 1.34), ROSE_MAT, 0.16, (math.radians(-8), 0, 0))
for arm_x in (-4.42, -2.34):
    rounded_box("Lounge sofa arm", (0.18, 0.76, 0.64), (arm_x, 1.83, 1.14), PANEL_LIT_MAT, 0.11)
cylinder("Lounge side table base", 0.25, 0.48, (-2.14, 1.58, 0.55), METAL_MAT)
cylinder("Lounge side table top", 0.42, 0.08, (-2.14, 1.58, 0.84), CREAM_MAT)
rounded_box("Lounge book", (0.38, 0.28, 0.07), (-2.14, 1.58, 0.91), CORAL_MAT, 0.022, (0, 0, math.radians(18)))

# Lived-in architectural details: a lit side window and an analog clock make
# the studio larger without relying on downloaded models or textures.
rounded_box("Side window frame", (0.10, 2.52, 1.72), (-5.53, -0.92, 4.08), METAL_MAT, 0.10)
rounded_box("Side window night glass", (0.028, 2.24, 1.44), (-5.47, -0.92, 4.08), BLUE_MAT, 0.045)
rounded_box("Window horizontal mullion", (0.055, 2.18, 0.055), (-5.44, -0.92, 4.08), CREAM_MAT, 0.018)
rounded_box("Window vertical mullion", (0.055, 0.055, 1.36), (-5.44, -0.92, 4.08), CREAM_MAT, 0.018)
for star_index, (star_y, star_z) in enumerate(((-1.72, 4.57), (-0.76, 4.42), (-0.12, 3.78), (-1.12, 3.66))):
    uv_sphere(f"Window warm star {star_index}", (-5.43, star_y, star_z), (0.035, 0.035, 0.035), PEACH_MAT)

cylinder("Wall clock face", 0.42, 0.07, (1.76, 3.72, 4.72), CREAM_MAT, (math.radians(90), 0, 0))
torus("Wall clock rim", 0.43, 0.037, (1.76, 3.67, 4.72), CORAL_MAT, (math.radians(90), 0, 0))
pipe("Clock minute hand", [(1.76, 3.64, 4.72), (1.95, 3.64, 4.98)], 0.025, PANEL_MAT)
pipe("Clock hour hand", [(1.76, 3.64, 4.72), (1.52, 3.64, 4.72)], 0.032, PANEL_MAT)
for tick_index in range(12):
    tick_angle = math.radians(tick_index * 30)
    uv_sphere(
        f"Clock tick {tick_index}",
        (1.76 + math.cos(tick_angle) * 0.31, 3.64, 4.72 + math.sin(tick_angle) * 0.31),
        (0.018, 0.018, 0.018),
        METAL_MAT,
    )

# The mounted bike uses only tubes, wheels and pads. It reads as a real object
# on the open left wall from the default three-quarter camera.
bike_x = -5.38
bike_back_y, bike_front_y, bike_z = -1.92, 0.42, 2.54
torus("Wall bicycle rear wheel", 0.49, 0.052, (bike_x, bike_back_y, bike_z), METAL_MAT, (0, math.radians(90), 0))
torus("Wall bicycle front wheel", 0.49, 0.052, (bike_x, bike_front_y, bike_z), METAL_MAT, (0, math.radians(90), 0))
pipe("Wall bicycle lower frame", [(bike_x, bike_back_y, bike_z), (bike_x, -0.72, bike_z), (bike_x, bike_front_y, bike_z)], 0.045, CORAL_MAT)
pipe("Wall bicycle top frame", [(bike_x, bike_back_y, bike_z), (bike_x, -0.70, bike_z + 0.82), (bike_x, bike_front_y, bike_z)], 0.045, CORAL_MAT)
pipe("Wall bicycle seat tube", [(bike_x, -0.72, bike_z), (bike_x, -0.92, bike_z + 0.92)], 0.042, CORAL_MAT)
pipe("Wall bicycle fork", [(bike_x, bike_front_y, bike_z), (bike_x, 0.18, bike_z + 0.90)], 0.040, CREAM_MAT)
pipe("Wall bicycle handlebar", [(bike_x, 0.18, bike_z + 0.90), (bike_x, 0.38, bike_z + 1.06), (bike_x, 0.62, bike_z + 1.0)], 0.035, CREAM_MAT)
rounded_box("Wall bicycle saddle", (0.08, 0.38, 0.10), (bike_x, -1.03, bike_z + 0.98), INK_MAT, 0.035)
cylinder("Wall bicycle crank", 0.10, 0.05, (bike_x, -0.72, bike_z), PEACH_MAT, (0, math.radians(90), 0))
pipe("Wall bicycle chain", [(bike_x, -0.72, bike_z - 0.04), (bike_x, bike_back_y + 0.22, bike_z - 0.04)], 0.017, METAL_MAT)

# Glass-fronted cabinet in the far-right corner: a few hand-built toys create
# parallax and prevent the room from feeling like a sparse showroom.
rounded_box("Toy cabinet outer", (1.34, 0.52, 3.34), (5.02, 3.50, 1.94), METAL_MAT, 0.10)
rounded_box("Toy cabinet interior", (1.13, 0.045, 3.05), (5.02, 3.20, 1.94), INK_MAT, 0.045)
for shelf_index, shelf_z in enumerate((0.92, 1.67, 2.42)):
    rounded_box(f"Toy cabinet shelf {shelf_index}", (1.10, 0.23, 0.07), (5.02, 3.16, shelf_z), PANEL_LIT_MAT, 0.025)
rounded_box("Toy cabinet glass door", (1.18, 0.026, 3.10), (5.02, 3.13, 1.94), BLUE_MAT, 0.035)
rounded_box("Toy cabinet divider", (0.045, 0.045, 3.02), (5.02, 3.10, 1.94), CREAM_MAT, 0.014)
create_gem((4.73, 3.06, 1.18), 0.17, PEACH_MAT)
uv_sphere("Cabinet planet toy", (5.29, 3.06, 1.18), (0.20, 0.20, 0.20), BLUE_MAT)
torus("Cabinet planet ring", 0.22, 0.018, (5.29, 3.06, 1.18), CREAM_MAT, (math.radians(68), 0, 0))
rounded_box("Cabinet robot body", (0.26, 0.16, 0.30), (4.80, 3.05, 1.91), CORAL_MAT, 0.05)
uv_sphere("Cabinet robot head", (4.80, 3.04, 2.12), (0.17, 0.11, 0.14), CREAM_MAT)
uv_sphere("Cabinet robot eye left", (4.74, 2.93, 2.13), (0.025, 0.015, 0.025), PANEL_MAT)
uv_sphere("Cabinet robot eye right", (4.86, 2.93, 2.13), (0.025, 0.015, 0.025), PANEL_MAT)
torus("Cabinet ring toy", 0.17, 0.04, (5.28, 3.04, 1.92), PEACH_MAT, (math.radians(90), 0, 0))
rounded_box("Cabinet toy block", (0.30, 0.17, 0.28), (4.77, 3.04, 2.66), ROSE_MAT, 0.05)
create_gem((5.26, 3.04, 2.66), 0.17, CORAL_MAT)
rounded_box("Toy cabinet label", (0.74, 0.028, 0.16), (5.02, 3.10, 3.28), CREAM_MAT, 0.035)
text_mesh("PLAY", (5.02, 3.08, 3.28), 0.105, PANEL_MAT, (math.radians(90), 0, 0))

# Wall artwork and a Serein crystal make the studio identifiably ours.
rounded_box("Logo art frame", (2.1, 0.09, 2.35), (3.35, 3.86, 3.64), INK_MAT, 0.10)
create_gem((3.35, 3.77, 3.95), 0.56, CORAL_MAT)
text_mesh("SEREIN", (3.35, 3.77, 2.96), 0.27, CREAM_MAT, (math.radians(90), 0, 0))
rounded_box("Acoustic panel A", (1.65, 0.06, 1.72), (-0.92, 3.83, 3.66), PANEL_LIT_MAT, 0.10)
rounded_box("Acoustic panel B", (1.25, 0.06, 1.22), (0.63, 3.83, 2.7), PANEL_LIT_MAT, 0.10)
for panel_x, panel_z in ((-0.92, 3.66), (0.63, 2.7)):
    for stripe in range(4):
        rounded_box("Acoustic slat", (0.86, 0.026, 0.055), (panel_x, 3.77, panel_z + 0.43 - stripe * 0.28), METAL_MAT, 0.018)

# Discreet cables ground the scene in a real working environment.
pipe("Monitor cable", [(0.15, 0.98, 2.27), (0.15, 1.3, 2.1), (0.55, 1.45, 2.03), (0.55, 2.55, 0.26)], 0.026, INK_MAT)
pipe("Desk cable", [(-1.45, 0.82, 2.03), (-1.45, 1.2, 1.7), (-1.2, 1.55, 0.28)], 0.022, INK_MAT)

# Camera, lights and render settings.
bpy.ops.object.camera_add(location=(10.8, -15.6, 9.2))
camera = bpy.context.active_object
camera.name = "Serein cinematic camera"
camera.data.lens = 49
look_at(camera, (0.0, 0.72, 2.15))
bpy.context.scene.camera = camera

def area_light(name, location, energy, color, size, target):
    bpy.ops.object.light_add(type="AREA", location=location)
    light = bpy.context.active_object
    light.name = name
    light.data.energy = energy
    light.data.color = color[:3]
    light.data.shape = "DISK"
    light.data.size = size
    look_at(light, target)
    return light


area_light("Key softbox", (-4.4, -5.1, 8.5), 1600, CREAM, 5.0, (0.0, 0.7, 2.0))
area_light("Coral rim", (5.8, 2.1, 6.3), 1250, CORAL, 3.2, (0.7, 0.5, 2.4))
area_light("Back warm bounce", (-2.0, 3.3, 5.5), 1100, PEACH, 3.4, (-0.2, 0.5, 2.4))
bpy.ops.object.light_add(type="POINT", location=(0.2, -0.4, 4.9))
bpy.context.active_object.data.energy = 180
bpy.context.active_object.data.color = PEACH[:3]

world = bpy.context.scene.world or bpy.data.worlds.new("World")
bpy.context.scene.world = world
world.use_nodes = True
world.node_tree.nodes["Background"].inputs["Color"].default_value = (0.025, 0.032, 0.048, 1.0)
world.node_tree.nodes["Background"].inputs["Strength"].default_value = 0.52

scene = bpy.context.scene
scene.render.engine = "BLENDER_EEVEE"
scene.render.resolution_x = 1600
scene.render.resolution_y = 1040
scene.render.resolution_percentage = 100
scene.render.image_settings.file_format = "PNG"
scene.render.image_settings.color_mode = "RGBA"
scene.render.film_transparent = False
scene.render.resolution_percentage = 100
scene.render.filepath = str(PREVIEW_PNG)
scene.render.use_file_extension = True
scene.render.image_settings.color_depth = "8"
scene.render.engine = "BLENDER_EEVEE"
try:
    scene.view_settings.look = "AgX - Medium High Contrast"
except TypeError:
    pass

bpy.ops.wm.save_as_mainfile(filepath=str(OUTPUT_BLEND))
bpy.ops.render.render(write_still=True)
bpy.ops.export_scene.gltf(
    filepath=str(OUTPUT_GLB),
    export_format="GLB",
    export_apply=True,
    export_materials="EXPORT",
    export_yup=True,
    export_cameras=False,
    export_lights=False,
)

print(f"SEREIN_STUDIO_GLB={OUTPUT_GLB}")
print(f"SEREIN_STUDIO_PREVIEW={PREVIEW_PNG}")
