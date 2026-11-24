## OpenGL drawing for the map views: the level geometry (textured, lit by its
## baked vertex colors), invisible faces (always, light cyan), marker faces
## and AI rooms as optional overlays, brushes being created (textured, see PreviewTint), per-frame line and
## triangle lists for objects, selection, grids and tool feedback, and the axis
## compass in each view's corner.

import std/[tables, sets, os, math, strutils, algorithm]
import opengl, vmath
import collada, tga, camera, geometry, thumbs, project

type
  FlatVert* = object
    pos*: Vec3
    col*: array[4, uint8]

  LevelVert = object
    pos: Vec3
    uv: Vec2
    col: array[4, uint8]
    nrm: Vec3                      ## Face normal (level geometry: picks the grid's plane); models: vertex normal.
    untint: array[4, uint8]        ## Face.untint (255 minus the tint; zero = none): Unlit shows the tint.

  DrawRange = object
    first, count: int32
    tex: GLuint
    alphaTest: bool
    gridDark: bool                 ## Black 3D grid lines (bright texture), else white.
    twoSided: bool                 ## Drawn from both sides even when r.cullBack is on.
    blend: bool                    ## A see-through texture's face: blended, after the solid ones, far to near.
    center: Vec3                   ## That face's middle (its distance orders the blended faces).

  Layer* = enum lGeometry, lInvisible, lMarkers, lRooms, lPreview,
    lGeometryEdges, lInvisibleEdges, lMarkerEdges   ## Face outlines (no triangle diagonals).

  ModelInstance* = object
    path*: string                  ## Saved model (thumbs.saveModel).
    base*: string                  ## The folder its image names are relative to.
    image*: string                 ## Replaces all its textures ("" = its own).
    transform*: M4
    tint*: Vec4                    ## Solid in 3D.
    wire*: array[4, uint8]         ## Wireframe color in 2D.

  MeshLayer = object
    vao, vbo: GLuint
    draws: seq[DrawRange]
    lines: bool                    ## GL_LINES, else GL_TRIANGLES.

  LiveVert = object
    ## A vertex of an animated corner (setGeometry), recolored by setLiveColors.
    layer: Layer
    index, face, corner: int32

  FogLook* = object
    ## Oni's fog as its OpenGL renderer applies it: linear in the projected
    ## depth z (its gluPerspective-style projection, near plane 2), from start
    ## to end (Bungie's gl_engine.c, glFogf with z scaled by 65535).
    on*: bool
    color*: Vec3
    start*, finish*, near*, far*: float32

  Renderer* = ref object
    levelProg, flatProg: GLuint
    uLevelMvp, uLevelTex, uLevelUseTex, uLevelLight, uLevelTint, uLevelAlphaTest: GLint
    uLevelGrid, uLevelGridSize, uLevelGridColor, uLevelGridAlpha, uLevelGridThickness, uLevelBrightness: GLint
    uLevelSkyBlend, uLevelSkyTint, uLevelSkyGain: GLint
    skyPass: bool                  ## drawMesh is drawing the sky.
    fog*: FogLook                  ## Realtime preview's fog (setFog); off unless shown.
    fogNow: bool                   ## The draws being made now take it (level, models, particles).
    uLevelFog, uLevelFogColor, uLevelFogParams, uSpriteFog, uSpriteFogColor, uSpriteFogParams: GLint
    uLevelFacing, uLevelViewDir: GLint
    uOniLit, uNormalMat, uOniDir, uOniColor, uOniAmbient: GLint
    uFlatMvp: GLint
    layers: array[Layer, MeshLayer]
    models: Table[string, MeshLayer]   ## Model path -> uploaded mesh (empty if unreadable).
    modelInstances*: seq[ModelInstance]  ## Per frame: models to draw.
    textures: Table[string, (GLuint, bool)]   ## path -> (texture, has alpha)
    brightTextures: Table[string, bool]       ## path -> TrenchBroom's "bright material" test
    textureLumas: Table[string, float32]      ## path -> luma of its average color (0..1)
    modelTextures: seq[string]     ## Texture paths the uploaded models use.
    dynVao, dynVbo: GLuint
    lines*: seq[FlatVert]          ## Depth-tested lines (object boxes).
    tris*: seq[FlatVert]           ## Translucent fills (selection), no depth write.
    overlayTris*: seq[FlatVert]    ## Fills drawn on top (tool feedback), under overlayLines.
    overlayLines*: seq[FlatVert]   ## Drawn on top (selection outlines, tool feedback).
    gridLines*: seq[FlatVert]      ## Per 2D view, as triangles (lines with a width); drawn behind everything.
    fullbright: bool               ## Vertex colors ignored (set per view from its RenderMode).
    showTint: bool                 ## With fullbright: faces in their tint instead of white (Unlit).
    uLevelShowTint: GLint
    cullBack: bool                 ## Skip back faces of one-sided draws (solid 3D geometry).
    camPos: Vec3                   ## The view being drawn's camera (orders blended faces).
    uLevelBlend: GLint
    showTriangles*: bool           ## Wireframes draw the triangles, else only face outlines.
    gridColor*: Vec3               ## 2D grid lines (alpha from gridAlpha), and 3D when gridColor3D.
    gridColor3D*: bool             ## The 3D face grid in gridColor instead of black/white per texture.
    liveVerts: seq[LiveVert]
    liveData: array[Layer, seq[LevelVert]]   ## CPU copies of the layers with live vertices.
    liveShown: bool                ## The animated colors are on the GPU (not the baked ones).
    grid3D*: float32               ## Grid size drawn on 3D faces; 0 = hidden.
    gridAlpha*: float32            ## Opacity of the 3D grid lines (render/Grid/Alpha).
    gridThickness*: float32        ## Grid line width in pixels, 2D and 3D views.
    brightness*: float32           ## Multiplies the 3D view's colors (render/Brightness).
    linearFilter: bool             ## Textures' current filter (setTextureFilter).
    geometryVersion*: int          ## Geometry.version last uploaded.
    previewKey*: string            ## What lPreview holds (setPreview); "" = nothing.
    skyName: string                ## Sky the skybox mesh shows ("" = none).
    skyMesh: MeshLayer             ## Cube around the 3D camera (setSky).
    skyGrade*: SkyGrade            ## The level's brightness and tint of it, live.
    spriteProg: GLuint
    uSpriteMvp, uSpriteTex: GLint
    spriteVao, spriteVbo: GLuint
    sprites*: seq[SpriteInst]      ## Per frame: particles for the 3D views (Realtime preview).
    particleTris*: seq[ParticleTri]  ## Per frame: their contrails and models.
    clampedTextures: HashSet[GLuint]
    arrows*: seq[DirArrow]         ## Per frame: where entities point.
    facing: bool                   ## Faces darken as they turn from the view (Solid; viewDir).
    viewDir: Vec3
    cavityProg, cavityVao, cavityFbo, cavityDepth: GLuint
    cavitySize: (int32, int32)     ## cavityDepth's size.
    uCavityDepth, uCavityOrigin, uCavityPixel, uCavityProj, uCavityNearFar: GLint
    uvProg, uvVao, uvVbo: GLuint   ## The Face tab's UV view (drawUvTexture); made on first use.
    uUvTex, uUvBrightness, uUvBack: GLint

  DirArrow* = object
    ## An entity's direction, in the translation gizmo's arrow shape (sized per view).
    base*, dir*: Vec3              ## dir is a unit vector.
    col*: array[4, uint8]
    onTop*: bool                   ## Drawn over everything (selected).

  RenderMode* = enum
    rmDynamicLight = "Dynamic Light"   ## Textures lit by the vertex colors.
    rmUnlit = "Unlit"                  ## Textures at full brightness.
    rmLighting = "Lighting"            ## The vertex colors only.
    rmSolid = "Solid"                  ## Plain faces shaded by their angle to the view, with cavity.
    rmWireframe = "Wireframe"
    rmLitWireframe = "Lit Wireframe"   ## Edges in their vertex colors.

  SpriteInst* = object
    ## A particle to draw (particlesim.nim): its quad is built per view.
    pos*: Vec3
    mode*: int                     ## Oni's display type: 0 sprite, 1 rotated sprite, 2 beam,
                                   ## 3 arrow, 4 flat, 7 discus, 8 decal.
    ax*: array[3, Vec3]            ## X, Y (its heading: orientation or velocity), Z (up).
    perp*: Vec3                    ## What edge fading measures the view against (zero = nothing).
    scale*, yscale*: float32       ## Half-size along the sprite's X and Y.
    rot*: float32                  ## Degrees, turning the sprite in its plane.
    xOffset*, xShorten*: float32   ## Where the sprite sits along its X; how much is cut off.
    col*: array[4, uint8]
    tex*: string                   ## TGA path.
    additive*, flare*: bool        ## Added to what's behind; drawn over the level (lens flare).
    sky*: bool                     ## DrawAsSky: never fogged, like the sky.
    edgeFade*, oneSided*: bool     ## Fades out seen edge-on, between edgeMin and edgeMax.
    edgeMin*, edgeMax*: float32

  ParticleTri* = object
    ## A triangle of a contrail or geometry particle (particlesim.nim), in world space.
    p*: array[3, Vec3]
    uv*: array[3, Vec2]
    col*: array[3, array[4, uint8]]
    tex*: string                   ## TGA path.
    additive*: bool
    wrap*: bool                    ## Its texture repeats (models); contrails clamp like sprites.
    sky*: bool                     ## DrawAsSky: never fogged.

  SpriteVert = object
    pos: Vec3
    uv: Vec2
    col: array[4, uint8]

  ViewOptions* = object
    mode*: RenderMode              ## How the 3D views draw the level (2D views are wireframe).
    rooms*, markers*: bool
    models*: bool                  ## Entity models at their objects.
    sky*: bool                     ## The level's skybox behind the 3D view.

const
  InvisibleTint = vec4(0.55, 0.95, 1.0, 0.30)
    ## Invisible faces: light cyan, drawn even with marker faces hidden so a
    ## brush that's invisible on every side can still be seen and clicked
    ## (unless the view header's Editor-only button hides them).
  PreviewTint = vec4(1, 0.85, 0.85, 0.7)
    ## Brushes being created: TrenchBroom's CreateBrushesToolBase draws them
    ## tinted with the selected face color and 70 % opaque.
  levelVs = """
#version 410 core
layout(location = 0) in vec3 aPos;
layout(location = 1) in vec2 aUv;
layout(location = 2) in vec4 aCol;
layout(location = 3) in vec3 aNrm;
layout(location = 4) in vec4 aUntint;
uniform mat4 uMvp;
uniform int uOniLit;        // Models: lit per vertex as Oni lights them (thumbs.nim, oniShade).
uniform mat3 uNormalMat;    // Their normals to world space.
uniform vec3 uOniDir[2];    // Toward each light.
uniform float uOniColor[2];
uniform float uOniAmbient;
out vec2 vUv;
out vec4 vCol;
out vec3 vTint;
out vec3 vPos;
out float vDepth;
// flat: interpolating a 45-degree face's normal flips the grid's plane
// choice (a.x vs a.z) from pixel to pixel.
flat out vec3 vNrm;
void main() {
  gl_Position = uMvp * vec4(aPos, 1.0);
  vDepth = gl_Position.w;   // Distance along the view (perspective w).
  vUv = aUv;
  vCol = aCol;
  if (uOniLit == 1) {
    vec3 n = uNormalMat * aNrm;
    float s = uOniAmbient;
    if (dot(n, n) > 1e-12) {
      n = normalize(n);
      for (int i = 0; i < 2; i++) s += max(dot(n, uOniDir[i]), 0.0) * uOniColor[i];
    }
    vCol.rgb *= floor(min(s * 255.0, 255.0) + 0.5) / 255.0;
  }
  vTint = 1.0 - aUntint.rgb;
  vPos = aPos;
  vNrm = aNrm;
}
"""
  levelFs = """
#version 410 core
in vec2 vUv;
in vec4 vCol;
in vec3 vTint;
in vec3 vPos;
in float vDepth;
flat in vec3 vNrm;
uniform sampler2D uTex;
uniform int uUseTex;
uniform int uAlphaTest;
uniform int uBlend;         // Oni's see-through textures: the texture's alpha, blended.
uniform float uLight;
uniform int uShowTint;      // Unlit: the face's tint instead of white where uLight drops the vertex colors.
uniform vec4 uTint;
uniform int uGrid;
uniform float uGridSize;
uniform vec3 uGridColor;
uniform float uGridAlpha;   // TrenchBroom's render/Grid/Alpha (default 0.5).
uniform float uGridThickness; // Line width in pixels.
uniform float uBrightness;  // TrenchBroom's render/Brightness.
uniform int uFacing;        // Solid mode: each face's brightness follows its angle to the view.
uniform vec3 uViewDir;
uniform int uSkyBlend;      // The sky's blend mode (skygrade.nim), -1 for anything else.
uniform vec3 uSkyTint;
uniform float uSkyGain;
uniform int uFog;           // Realtime preview's fog, as Oni draws it (FogLook).
uniform vec3 uFogColor;
uniform vec4 uFogParams;    // Start, end (projected depth), Oni's near and far planes.

float oniFog(float d) {
  // How much of the color stays: Oni's projected z at view depth d, then
  // OpenGL's linear fog between start and end.
  float n = uFogParams.z;
  float f = uFogParams.w;
  float z = (f + n) / (f - n) - 2.0 * f * n / ((f - n) * max(d, 1e-4));
  float s = uFogParams.x;
  float e = uFogParams.y;
  if (e <= s) return z < e ? 1.0 : 0.0;
  return clamp((e - z) / (e - s), 0.0, 1.0);
}
out vec4 fragColor;

// The 3D face grid, after TrenchBroom 2025.4 (Face.fragsh + Grid.fragsh): a major
// line every 64 units, and finer grids fading into the next coarser one. Unlike
// TrenchBroom, the lines are uGridThickness pixels wide at any distance (as in the
// 2D views), fully opaque across that width with a one-pixel antialiased edge.
// TrenchBroom's lines (2 pixels with a wider soft edge) never reached full strength
// up close, and stayed 2 pixels while the grid shrank to 4 pixels far away, so the
// lines covered the faces there. Here a grid step is only drawn while its lines stay
// at least GridMinSpacing line widths apart on screen; finer ones fade out.

const float GridMinSpacing = 8.0;   // Grid step at least this many line widths on screen.

float gridAxis(float v, float g, float cell, float w) {
  // Coverage of the lines of one axis: v the world coordinate, g the world units per
  // pixel across those lines, cell the grid step, w the line width in pixels.
  float dist = abs(fract(v / cell + 0.5) - 0.5) * cell / max(g, 1e-6);
  float wide = max(w, 1.0);
  float cover = clamp(wide * 0.5 + 0.5 - dist, 0.0, 1.0) * min(w, 1.0);
  // A major line where the nearest line falls on a multiple of 64.
  float isMajor = step(abs(fract(v / 64.0 + 0.5) - 0.5) * 64.0, cell * 0.5);
  return cover * (isMajor * 0.7 + 0.85);
}

float gridLevel(vec2 c, vec2 g, float cell, float w) {
  return max(gridAxis(c.x, g.x, cell, w), gridAxis(c.y, g.y, cell, w));
}

// Normals closer than this count as a tie when picking the grid's plane (about 0.3
// degrees either side of 45). A wall at exactly 45 degrees has |x| == |z|, and float
// noise in each face's normal flipped the choice from face to face, so the lines
// jumped between the pieces of one wall. Noise reaches ~0.004 on sliver triangles;
// 1e-2 left no touching coplanar faces disagreeing in any project (tmp/gridtie).
const float GridAxisTie = 1e-2;

float grid(vec3 p, vec3 n) {
  vec3 a = abs(n);
  vec2 c;
  // TrenchBroom's order; a tie goes to the later axis, as an exact tie does there.
  if (a.x > a.y + GridAxisTie) c = a.x > a.z + GridAxisTie ? p.yz : p.xy;
  else c = a.y > a.z + GridAxisTie ? p.xz : p.xy;
  // World units per screen pixel across each axis's lines.
  vec2 g = vec2(length(vec2(dFdx(c.x), dFdy(c.x))), length(vec2(dFdx(c.y), dFdy(c.y))));
  float w = uGridThickness;
  float minToRender = max(g.x, g.y) * GridMinSpacing * max(w, 1.0);
  float base = exp2(floor(log2(minToRender)));
  if (uGridSize > base) base = uGridSize;
  float next = 2.0 * base;
  float blend = smoothstep(base, next, minToRender);
  return mix(gridLevel(c, g, base, w), gridLevel(c, g, next, w), blend) * 0.5;
}

vec3 skyGrade(vec3 c) {
  // The same as gradePixel in skygrade.nim.
  vec3 b = min(c * uSkyGain, vec3(1.0));
  vec3 s = uSkyTint;
  const vec3 w = vec3(0.299, 0.587, 0.114);
  if (uSkyBlend == 1) return b * s;
  if (uSkyBlend == 2) return 1.0 - (1.0 - b) * (1.0 - s);
  if (uSkyBlend == 3) return mix(2.0 * b * s, 1.0 - 2.0 * (1.0 - b) * (1.0 - s), step(0.5, b));
  if (uSkyBlend == 4) return (1.0 - 2.0 * s) * b * b + 2.0 * s * b;
  if (uSkyBlend == 5) return min(b + s, vec3(1.0));
  if (uSkyBlend == 6) return min(s * dot(b, w) / max(dot(s, w), 0.001), vec3(1.0));
  return b;
}

void main() {
  vec4 t = uUseTex == 1 ? texture(uTex, vUv) : vec4(1.0);
  if (uAlphaTest == 1 && t.a < 0.5) discard;
  vec3 lit = mix(vCol.rgb, uShowTint == 1 ? vTint : vec3(1.0), uLight);
  fragColor = vec4(min(t.rgb * lit * uBrightness, vec3(1.0)), uBlend == 1 ? t.a : 1.0) * uTint;
  if (uSkyBlend >= 0) fragColor.rgb = skyGrade(fragColor.rgb);
  if (uFacing == 1)
    fragColor.rgb *= mix(0.3, 0.9, abs(dot(vNrm, uViewDir)));
  if (uFog == 1) fragColor.rgb = mix(uFogColor, fragColor.rgb, oniFog(vDepth));
  if (uGrid == 1)
    fragColor.rgb = mix(fragColor.rgb, uGridColor, grid(vPos, vNrm) * uGridAlpha);
}
"""
  spriteVs = """
#version 410 core
layout(location = 0) in vec3 aPos;
layout(location = 1) in vec2 aUv;
layout(location = 2) in vec4 aCol;
uniform mat4 uMvp;
out vec2 vUv;
out vec4 vCol;
out float vDepth;
void main() {
  gl_Position = uMvp * vec4(aPos, 1.0);
  vDepth = gl_Position.w;
  vUv = aUv;
  vCol = aCol;
}
"""
  spriteFs = """
#version 410 core
in vec2 vUv;
in vec4 vCol;
in float vDepth;
uniform sampler2D uTex;
uniform int uFog;           // Realtime preview's fog, as Oni draws it (FogLook).
uniform vec3 uFogColor;
uniform vec4 uFogParams;    // Start, end (projected depth), Oni's near and far planes.

float oniFog(float d) {
  // How much of the color stays: Oni's projected z at view depth d, then
  // OpenGL's linear fog between start and end.
  float n = uFogParams.z;
  float f = uFogParams.w;
  float z = (f + n) / (f - n) - 2.0 * f * n / ((f - n) * max(d, 1e-4));
  float s = uFogParams.x;
  float e = uFogParams.y;
  if (e <= s) return z < e ? 1.0 : 0.0;
  return clamp((e - z) / (e - s), 0.0, 1.0);
}
out vec4 fragColor;
void main() {
  fragColor = texture(uTex, vUv) * vCol;
  // As fixed-function fog: the color only. Additive textures are never fogged
  // (drawSprites turns it off for them, as Oni does).
  if (uFog == 1) fragColor.rgb = mix(uFogColor, fragColor.rgb, oniFog(vDepth));
}
"""
  cavityVs = """
#version 410 core
void main() {
  vec2 p = vec2((gl_VertexID & 1) * 4 - 1, (gl_VertexID & 2) * 2 - 1);
  gl_Position = vec4(p, 0.0, 1.0);
}
"""
  cavityFs = """
#version 410 core
// Solid mode's cavity, from the depth buffer alone, as Blender's Workbench does
// it: screen-space curvature brightens ridges and darkens valleys along edges,
// and a small ambient occlusion darkens corners. The output multiplies what's
// drawn, doubled (0.5 = no change).
uniform sampler2D uDepth;
uniform vec2 uOrigin;      // The view's corner in the window, in pixels.
uniform vec2 uPixel;       // Size of a pixel in UV.
uniform vec2 uProj;        // Projection scale in x and y.
uniform vec2 uNearFar;
out vec4 fragColor;

const float Radius = 22.0;     // World units the occlusion reaches.
const int Samples = 32;

vec3 viewPos(vec2 uv) {
  float d = texture(uDepth, uv).r * 2.0 - 1.0;
  float z = 2.0 * uNearFar.x * uNearFar.y / (uNearFar.y + uNearFar.x - d * (uNearFar.y - uNearFar.x));
  return vec3((uv * 2.0 - 1.0) / uProj * z, -z);
}

vec3 normalAt(vec2 uv, vec3 c) {
  // The nearer neighbor on each axis, so silhouettes stay out of the normal.
  vec3 l = viewPos(uv - vec2(uPixel.x, 0.0)) - c;
  vec3 r = viewPos(uv + vec2(uPixel.x, 0.0)) - c;
  vec3 b = viewPos(uv - vec2(0.0, uPixel.y)) - c;
  vec3 t = viewPos(uv + vec2(0.0, uPixel.y)) - c;
  vec3 dx = abs(r.z) < abs(l.z) ? r : -l;
  vec3 dy = abs(t.z) < abs(b.z) ? t : -b;
  return normalize(cross(dx, dy));
}

float fold(vec2 uv, vec3 c, vec2 step) {
  // How much the normal turns across this pixel along a screen axis; + = ridge.
  vec2 u0 = uv - step, u1 = uv + step;
  if (texture(uDepth, u0).r >= 1.0 || texture(uDepth, u1).r >= 1.0) return 0.0;
  vec3 p0 = viewPos(u0), p1 = viewPos(u1);
  // A jump in depth is a silhouette, not a fold.
  if (abs(p0.z - c.z) + abs(p1.z - c.z) > 0.004 * -c.z + 1.0) return 0.0;
  vec3 n0 = normalAt(u0, p0), n1 = normalAt(u1, p1);
  vec2 s = normalize(step / uPixel);
  return dot(n1.xy - n0.xy, s);
}

void main() {
  vec2 uv = (gl_FragCoord.xy - uOrigin) * uPixel;
  if (texture(uDepth, uv).r >= 1.0) discard;
  vec3 c = viewPos(uv);
  vec3 n = normalAt(uv, c);
  float curve = fold(uv, c, vec2(uPixel.x, 0.0)) + fold(uv, c, vec2(0.0, uPixel.y));
  float ridge = clamp(curve, 0.0, 1.0), valley = clamp(-curve, 0.0, 1.0);
  // Interleaved gradient noise turns the sample spiral per pixel.
  float noise = fract(52.9829189 * fract(dot(gl_FragCoord.xy, vec2(0.06711056, 0.00583715))));
  float px = clamp(Radius * uProj.y * 0.5 / uPixel.y / -c.z, 3.0, 40.0);
  float occl = 0.0;
  for (int i = 0; i < Samples; i++) {
    float a = (float(i) * 2.4 + noise) * 6.2831853;
    float r = sqrt((float(i) + 0.5) / float(Samples)) * px;
    vec3 v = viewPos(uv + r * vec2(cos(a), sin(a)) * uPixel) - c;
    float d = length(v);
    if (d < 1e-3) continue;
    float near = clamp(1.0 - d / (Radius * 1.5), 0.0, 1.0);
    occl += max(dot(n, v) / d - 0.12, 0.0) * near;
  }
  occl = clamp(occl / float(Samples) * 2.2, 0.0, 0.75);
  float shade = (1.0 - occl) * (1.0 + 0.45 * ridge) * (1.0 - 0.5 * valley);
  fragColor = vec4(vec3(clamp(shade, 0.0, 2.0) * 0.5), 1.0);
}
"""
  flatVs = """
#version 410 core
layout(location = 0) in vec3 aPos;
layout(location = 1) in vec4 aCol;
uniform mat4 uMvp;
out vec4 vCol;
void main() {
  gl_Position = uMvp * vec4(aPos, 1.0);
  vCol = aCol;
}
"""
  flatFs = """
#version 410 core
in vec4 vCol;
out vec4 fragColor;
void main() { fragColor = vCol; }
"""

  uvVs = """
#version 410 core
// The Face tab's UV view: one quad over the view, its corners' UVs from the
// face's mapping (affine, so interpolating them is exact).
layout(location = 0) in vec2 aPos;
layout(location = 1) in vec2 aUv;
out vec2 vUv;
void main() {
  gl_Position = vec4(aPos, 0.0, 1.0);
  vUv = aUv;
}
"""
  uvFs = """
#version 410 core
uniform sampler2D uTex;
uniform float uBrightness;
uniform vec3 uBack;
in vec2 vUv;
out vec4 fragColor;
void main() {
  vec4 t = texture(uTex, vUv);
  // Unlit, as the level shader draws textures (see levelFs), over the view's
  // background where the texture is see-through.
  fragColor = vec4(mix(uBack, min(t.rgb * uBrightness, vec3(1.0)), t.a), 1.0);
}
"""

proc compile(kind: GLenum, src: string): GLuint =
  result = glCreateShader(kind)
  var s = src.cstring
  glShaderSource(result, 1, cast[cstringArray](s.addr), nil)
  glCompileShader(result)
  var ok: GLint
  glGetShaderiv(result, GL_COMPILE_STATUS, ok.addr)
  if ok == 0:
    var buf = newString(2048)
    var n: GLsizei
    glGetShaderInfoLog(result, 2048, n.addr, buf.cstring)
    raise newException(ValueError, "shader: " & buf[0 ..< n])

proc link(vs, fs: string): GLuint =
  result = glCreateProgram()
  glAttachShader(result, compile(GL_VERTEX_SHADER, vs))
  glAttachShader(result, compile(GL_FRAGMENT_SHADER, fs))
  glLinkProgram(result)

proc textured*(m: RenderMode): bool = m in {rmDynamicLight, rmUnlit}
proc wireframe*(m: RenderMode): bool = m in {rmWireframe, rmLitWireframe}

proc newRenderer*(): Renderer =
  result = Renderer(geometryVersion: -1, gridAlpha: 0.5, gridThickness: 1, brightness: 1, linearFilter: true,
                    showTriangles: true, gridColor: vec3(1, 1, 1))
  result.levelProg = link(levelVs, levelFs)
  result.uLevelMvp = glGetUniformLocation(result.levelProg, "uMvp")
  result.uLevelTex = glGetUniformLocation(result.levelProg, "uTex")
  result.uLevelUseTex = glGetUniformLocation(result.levelProg, "uUseTex")
  result.uLevelLight = glGetUniformLocation(result.levelProg, "uLight")
  result.uLevelTint = glGetUniformLocation(result.levelProg, "uTint")
  result.uLevelShowTint = glGetUniformLocation(result.levelProg, "uShowTint")
  result.uLevelAlphaTest = glGetUniformLocation(result.levelProg, "uAlphaTest")
  result.uLevelBlend = glGetUniformLocation(result.levelProg, "uBlend")
  result.uLevelGrid = glGetUniformLocation(result.levelProg, "uGrid")
  result.uLevelGridSize = glGetUniformLocation(result.levelProg, "uGridSize")
  result.uLevelGridColor = glGetUniformLocation(result.levelProg, "uGridColor")
  result.uLevelGridAlpha = glGetUniformLocation(result.levelProg, "uGridAlpha")
  result.uLevelGridThickness = glGetUniformLocation(result.levelProg, "uGridThickness")
  result.uLevelBrightness = glGetUniformLocation(result.levelProg, "uBrightness")
  result.uLevelSkyBlend = glGetUniformLocation(result.levelProg, "uSkyBlend")
  result.uLevelSkyTint = glGetUniformLocation(result.levelProg, "uSkyTint")
  result.uLevelSkyGain = glGetUniformLocation(result.levelProg, "uSkyGain")
  result.uLevelFacing = glGetUniformLocation(result.levelProg, "uFacing")
  result.uLevelViewDir = glGetUniformLocation(result.levelProg, "uViewDir")
  result.uOniLit = glGetUniformLocation(result.levelProg, "uOniLit")
  result.uNormalMat = glGetUniformLocation(result.levelProg, "uNormalMat")
  result.uOniDir = glGetUniformLocation(result.levelProg, "uOniDir")
  result.uOniColor = glGetUniformLocation(result.levelProg, "uOniColor")
  result.uOniAmbient = glGetUniformLocation(result.levelProg, "uOniAmbient")
  result.uLevelFog = glGetUniformLocation(result.levelProg, "uFog")
  result.uLevelFogColor = glGetUniformLocation(result.levelProg, "uFogColor")
  result.uLevelFogParams = glGetUniformLocation(result.levelProg, "uFogParams")
  result.flatProg = link(flatVs, flatFs)
  result.uFlatMvp = glGetUniformLocation(result.flatProg, "uMvp")
  result.spriteProg = link(spriteVs, spriteFs)
  result.uSpriteMvp = glGetUniformLocation(result.spriteProg, "uMvp")
  result.uSpriteTex = glGetUniformLocation(result.spriteProg, "uTex")
  result.uSpriteFog = glGetUniformLocation(result.spriteProg, "uFog")
  result.uSpriteFogColor = glGetUniformLocation(result.spriteProg, "uFogColor")
  result.uSpriteFogParams = glGetUniformLocation(result.spriteProg, "uFogParams")
  result.cavityProg = link(cavityVs, cavityFs)
  result.uCavityDepth = glGetUniformLocation(result.cavityProg, "uDepth")
  result.uCavityOrigin = glGetUniformLocation(result.cavityProg, "uOrigin")
  result.uCavityPixel = glGetUniformLocation(result.cavityProg, "uPixel")
  result.uCavityProj = glGetUniformLocation(result.cavityProg, "uProj")
  result.uCavityNearFar = glGetUniformLocation(result.cavityProg, "uNearFar")
  glGenVertexArrays(1, result.cavityVao.addr)
  glGenVertexArrays(1, result.spriteVao.addr)
  glGenBuffers(1, result.spriteVbo.addr)
  glBindVertexArray(result.spriteVao)
  glBindBuffer(GL_ARRAY_BUFFER, result.spriteVbo)
  glEnableVertexAttribArray(0)
  glVertexAttribPointer(0, 3, cGL_FLOAT, GL_FALSE, sizeof(SpriteVert).GLsizei, nil)
  glEnableVertexAttribArray(1)
  glVertexAttribPointer(1, 2, cGL_FLOAT, GL_FALSE, sizeof(SpriteVert).GLsizei, cast[pointer](12))
  glEnableVertexAttribArray(2)
  glVertexAttribPointer(2, 4, GL_UNSIGNED_BYTE, GL_TRUE, sizeof(SpriteVert).GLsizei,
    cast[pointer](20))
  glBindVertexArray(0)
  glGenVertexArrays(1, result.dynVao.addr)
  glGenBuffers(1, result.dynVbo.addr)
  glBindVertexArray(result.dynVao)
  glBindBuffer(GL_ARRAY_BUFFER, result.dynVbo)
  glEnableVertexAttribArray(0)
  glVertexAttribPointer(0, 3, cGL_FLOAT, GL_FALSE, sizeof(FlatVert).GLsizei, nil)
  glEnableVertexAttribArray(1)
  glVertexAttribPointer(1, 4, GL_UNSIGNED_BYTE, GL_TRUE, sizeof(FlatVert).GLsizei,
    cast[pointer](12))
  glBindVertexArray(0)

proc averageLuma(rgba: seq[uint8]): float32 =
  ## Luma (Rec. 601) of the image's average color, 0..1, from at most ~4096 pixels.
  let pixels = rgba.len div 4
  if pixels == 0: return 0
  let stride = max(1, pixels div 4096)
  var sum: array[3, float]
  var n = 0
  for i in countup(0, pixels - 1, stride):
    for c in 0 .. 2: sum[c] += rgba[i * 4 + c].float
    inc n
  float32((0.299 * sum[0] + 0.587 * sum[1] + 0.114 * sum[2]) / (n.float * 255))

proc isBrightForGrid(rgba: seq[uint8]): bool =
  ## TrenchBroom 2025.4's gridColorForMaterial: black grid lines when the
  ## texture's average color is brighter than 0.5, white otherwise. Its
  ## getAverageColor samples at most ~64 pixels and never divides the bytes by
  ## 255 before clamping each channel to 1, so in practice "bright" means at
  ## least two of R, G, B are nonzero on average. Copied as is so the lines
  ## pick the same color as in TrenchBroom.
  let pixels = rgba.len div 4
  if pixels == 0: return false
  let stride = if pixels <= 4192: 1 else: pixels div 64
  let samples = pixels div stride
  var sum: array[3, float32]
  for i in 0 ..< samples:
    for c in 0 .. 2: sum[c] += rgba[i * 4 * stride + c].float32
  var brightness = 0'f32
  for c in 0 .. 2: brightness += clamp(sum[c] / samples.float32, 0, 1)
  brightness / 3 > 0.5

proc setFilter(linear: bool) =
  ## The bound texture's filter: linear with mipmaps, or nearest (pixelated).
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER,
    (if linear: GL_LINEAR_MIPMAP_LINEAR else: GL_NEAREST_MIPMAP_NEAREST).GLint)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, (if linear: GL_LINEAR else: GL_NEAREST).GLint)

proc setTextureFilter*(r: Renderer, linear: bool) =
  ## TrenchBroom's View > Filter mode, for every loaded texture and later ones.
  if linear == r.linearFilter: return
  r.linearFilter = linear
  for _, (tex, _) in r.textures:
    if tex != 0:
      glBindTexture(GL_TEXTURE_2D, tex)
      setFilter(linear)

proc forgetMissingTexture*(r: Renderer, path: string) =
  ## A texture file that wasn't there when last looked for is read again on
  ## the next upload (it was put back).
  if path in r.textures and r.textures[path][0] == 0:
    r.textures.del path
    r.geometryVersion = -1

proc texture*(r: Renderer, path: string): (GLuint, bool) =
  if path in r.textures: return r.textures[path]
  result = (0.GLuint, false)
  if path.len > 0 and fileExists(path):
    try:
      let img = readTga(readFile(path))
      var tex: GLuint
      glGenTextures(1, tex.addr)
      glBindTexture(GL_TEXTURE_2D, tex)
      glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8.GLint, img.width.GLsizei, img.height.GLsizei, 0,
        GL_RGBA, GL_UNSIGNED_BYTE, img.rgba[0].unsafeAddr)
      glGenerateMipmap(GL_TEXTURE_2D)
      setFilter(r.linearFilter)
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_REPEAT.GLint)
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_REPEAT.GLint)
      result = (tex, img.seeThrough)
      r.brightTextures[path] = isBrightForGrid(img.rgba)
      r.textureLumas[path] = averageLuma(img.rgba)
    except CatchableError:
      discard
  r.textures[path] = result

proc deleteMesh(m: MeshLayer) =
  if m.vbo != 0:
    var b = m.vbo
    glDeleteBuffers(1, b.addr)
    var a = m.vao
    glDeleteVertexArrays(1, a.addr)

proc clearLayer(r: Renderer, layer: Layer) =
  deleteMesh(r.layers[layer])
  r.layers[layer] = MeshLayer()

proc newMesh(data: seq[LevelVert], draws: seq[DrawRange], lines = false): MeshLayer =
  var m = MeshLayer(draws: draws, lines: lines)
  if data.len > 0:
    glGenVertexArrays(1, m.vao.addr)
    glGenBuffers(1, m.vbo.addr)
    glBindVertexArray(m.vao)
    glBindBuffer(GL_ARRAY_BUFFER, m.vbo)
    glBufferData(GL_ARRAY_BUFFER, data.len * sizeof(LevelVert), data[0].unsafeAddr, GL_DYNAMIC_DRAW)
    let stride = sizeof(LevelVert).GLsizei
    glEnableVertexAttribArray(0)
    glVertexAttribPointer(0, 3, cGL_FLOAT, GL_FALSE, stride, nil)
    glEnableVertexAttribArray(1)
    glVertexAttribPointer(1, 2, cGL_FLOAT, GL_FALSE, stride, cast[pointer](12))
    glEnableVertexAttribArray(2)
    glVertexAttribPointer(2, 4, GL_UNSIGNED_BYTE, GL_TRUE, stride, cast[pointer](20))
    glEnableVertexAttribArray(3)
    glVertexAttribPointer(3, 3, cGL_FLOAT, GL_FALSE, stride, cast[pointer](24))
    glEnableVertexAttribArray(4)
    glVertexAttribPointer(4, 4, GL_UNSIGNED_BYTE, GL_TRUE, stride, cast[pointer](36))
    glBindVertexArray(0)
  m

proc upload(r: Renderer, layer: Layer, data: seq[LevelVert], draws: seq[DrawRange], lines = false) =
  r.clearLayer(layer)
  r.layers[layer] = newMesh(data, draws, lines)

proc untint4(f: Face): array[4, uint8] = [f.untint[0], f.untint[1], f.untint[2], 0]

proc isMarkerFace*(f: Face): bool =
  (f.flags and (gfGhost or gfDoorFrame)) != 0 or f.texture.startsWith("_marker")

proc isInvisibleFace*(f: Face): bool =
  ## An Invisible face that isn't also a marker (those keep the marker color).
  (f.flags and gfInvisible) != 0 and not f.isMarkerFace

proc setGeometry*(r: Renderer, g: Geometry, texturePath: proc(name: string): string,
                  hidden: proc(fi: int): bool) =
  ## Uploads the editable geometry: visible faces batched per texture, and
  ## invisible and marker faces into their own layers, plus each one's face
  ## outlines. Corners with a light animation are remembered for setLiveColors.
  var byTex: OrderedTable[(string, bool), seq[int]]
  var invis, marks: seq[int]
  for i, f in g.faces:
    if f.verts.len < 3 or hidden(i): continue
    if f.isMarkerFace: marks.add i
    elif f.isInvisibleFace: invis.add i
    else: byTex.mgetOrPut((f.texture, (f.flags and gfTwoSided) != 0), @[]).add i
  r.liveVerts.setLen 0
  r.liveShown = false
  proc live(r: Renderer, layer: Layer, index, fi, c: int) =
    let f = g.faces[fi]
    if f.animAt(c).mode != amNone or f.lightAnims.len > 0:
      r.liveVerts.add LiveVert(layer: layer, index: index.int32, face: fi.int32, corner: c.int32)
  proc emit(data: var seq[LevelVert], fi: int, layer: Layer) =
    let f = g.faces[fi]
    let n = g.normal(f)
    for k in 1 ..< f.verts.len - 1:
      for c in [0, k, k + 1]:
        if layer == lGeometry: r.live(layer, data.len, fi, c)
        data.add LevelVert(pos: g.points[f.verts[c]], uv: f.uvs[c], col: f.shownColor(c), nrm: n,
                           untint: f.untint4)
  proc edges(faces: seq[int], layer: Layer) =
    var data: seq[LevelVert]
    for fi in faces:
      let f = g.faces[fi]
      for k in 0 ..< f.verts.len:
        for c in [k, (k + 1) mod f.verts.len]:
          if layer == lGeometryEdges: r.live(layer, data.len, fi, c)
          data.add LevelVert(pos: g.points[f.verts[c]], col: f.shownColor(c), untint: f.untint4)
    r.upload(layer, data, @[DrawRange(first: 0, count: data.len.int32)], lines = true)
    r.liveData[layer] = data
  var data: seq[LevelVert]
  var draws: seq[DrawRange]
  var visible: seq[int]
  var blended: seq[DrawRange]
  for key, faces in byTex:
    let (tex, twoSided) = key
    let path = texturePath(tex)
    let (t, alpha) = r.texture(path)
    visible.add faces
    if alpha:
      # As Oni draws them (Build makes them Transparent and Two-sided): one
      # draw each, so they can be ordered by distance every frame.
      for fi in faces:
        let first = data.len
        data.emit(fi, lGeometry)
        var c = vec3(0, 0, 0)
        for v in g.faces[fi].verts: c += g.points[v]
        blended.add DrawRange(first: first.int32, count: int32(data.len - first), tex: t, blend: true,
                              center: c / g.faces[fi].verts.len.float32,
                              gridDark: r.brightTextures.getOrDefault(path), twoSided: true)
      continue
    let first = data.len
    for fi in faces: data.emit(fi, lGeometry)
    draws.add DrawRange(first: first.int32, count: int32(data.len - first), tex: t,
                        gridDark: r.brightTextures.getOrDefault(path), twoSided: twoSided)
  draws.add blended
  r.upload(lGeometry, data, draws)
  r.liveData[lGeometry] = data
  var idata, mdata: seq[LevelVert]
  for fi in invis: idata.emit(fi, lInvisible)
  r.upload(lInvisible, idata, @[DrawRange(first: 0, count: idata.len.int32)])
  for fi in marks: mdata.emit(fi, lMarkers)
  r.upload(lMarkers, mdata, @[DrawRange(first: 0, count: mdata.len.int32)])
  edges(visible, lGeometryEdges)
  edges(invis, lInvisibleEdges)
  edges(marks, lMarkerEdges)
  if r.liveVerts.len == 0:
    for l in Layer: r.liveData[l].setLen 0
  r.geometryVersion = g.version

proc setLiveColors*(r: Renderer, g: Geometry, seconds: float32, on: bool) =
  ## Realtime preview: plays the corners' light animations at seconds (on), or
  ## puts their baked colors back (off). Only the changed span of each buffer is sent.
  if r.liveVerts.len == 0 or (not on and not r.liveShown): return
  r.liveShown = on
  var lo, hi: array[Layer, int]
  for l in Layer: (lo[l], hi[l]) = (int.high, -1)
  for v in r.liveVerts:
    if v.face >= g.faces.len or v.corner >= g.faces[v.face].colors.len: continue
    let f = g.faces[v.face]
    let c = if on: f.liveColor(v.corner, seconds) else: f.shownColor(v.corner)
    r.liveData[v.layer][v.index].col = c
    lo[v.layer] = min(lo[v.layer], v.index)
    hi[v.layer] = max(hi[v.layer], v.index)
  for l in Layer:
    if hi[l] < 0 or r.layers[l].vbo == 0: continue
    glBindBuffer(GL_ARRAY_BUFFER, r.layers[l].vbo)
    glBufferSubData(GL_ARRAY_BUFFER, lo[l] * sizeof(LevelVert), (hi[l] - lo[l] + 1) * sizeof(LevelVert),
                    r.liveData[l][lo[l]].addr)

proc setPreview*(r: Renderer, key: string, g: Geometry, texturePath: proc(name: string): string) =
  ## Uploads the brushes being drawn or assembled (g; nil = none), textured as
  ## they will be once created. key names them, so unchanged ones aren't re-sent.
  if key == r.previewKey: return
  r.previewKey = key
  if g == nil or g.faces.len == 0:
    r.clearLayer(lPreview)
    return
  var byTex: OrderedTable[string, seq[int]]
  for i, f in g.faces:
    if f.verts.len >= 3: byTex.mgetOrPut(f.texture, @[]).add i
  var data: seq[LevelVert]
  var draws: seq[DrawRange]
  for tex, faces in byTex:
    let first = data.len
    for fi in faces:
      let f = g.faces[fi]
      let n = g.normal(f)
      for k in 1 ..< f.verts.len - 1:
        for c in [0, k, k + 1]:
          data.add LevelVert(pos: g.points[f.verts[c]], uv: f.uvs[c], col: f.shownColor(c), nrm: n,
                             untint: f.untint4)
    let path = texturePath(tex)
    let (t, alpha) = r.texture(path)
    draws.add DrawRange(first: first.int32, count: int32(data.len - first), tex: t, blend: alpha,
                        gridDark: r.brightTextures.getOrDefault(path))
  r.upload(lPreview, data, draws)

proc setRooms*(r: Renderer, scene: DaeScene) =
  var data: seq[LevelVert]
  for b in scene.batches:
    for v in b.verts: data.add LevelVert(pos: v.pos, uv: v.uv, col: v.color)
  r.upload(lRooms, data, @[DrawRange(first: 0, count: data.len.int32)])

proc model(r: Renderer, path, base, image: string): string =
  ## The saved model, uploaded on first use with its vertex normals: drawModels
  ## lights it per vertex as Oni does (thumbs.oniShade; the level's baked
  ## lighting doesn't reach objects). Models saved before normals were (CWM1)
  ## take their faces' normals. image, if given, textures all of it (console
  ## screens show their state's texture). Returns its key in r.models.
  let key = if image.len > 0: path & "|" & image else: path
  result = key
  if key in r.models: return
  var mesh = loadModel(path, base)
  if image.len > 0:
    mesh.images = @[image]
    for t in mesh.tris.mitems: t.tex = 0
  var byTex: OrderedTable[int, seq[LevelVert]]
  for t in mesh.tris:
    let fn = t.faceNormal
    if fn.length == 0: continue
    let smooth = t.hasNormals
    for k in 0 .. 2:
      byTex.mgetOrPut(t.tex, @[]).add LevelVert(pos: t.p[k], uv: t.uv[k], col: t.col[k],
                                                 nrm: (if smooth: t.n[k] else: fn))
  var data: seq[LevelVert]
  var draws: seq[DrawRange]
  r.modelTextures.add mesh.images
  for tex, verts in byTex:
    let (gl, alpha) = if tex >= 0: r.texture(mesh.images[tex]) else: (0.GLuint, false)
    draws.add DrawRange(first: data.len.int32, count: verts.len.int32, tex: gl, alphaTest: alpha)
    data.add verts
  r.models[key] = newMesh(data, draws)

proc clearModels*(r: Renderer) =
  ## Forgets the uploaded models (the library was rebuilt), and their
  ## textures, which the rebuild may have rewritten in place.
  for _, m in r.models: deleteMesh(m)
  r.models.clear()
  for path in r.modelTextures:
    if path in r.textures:
      var t = r.textures[path][0]
      if t != 0: glDeleteTextures(1, t.addr)
      r.textures.del path
      r.brightTextures.del path
  r.modelTextures.setLen 0

proc setSky*(r: Renderer, name: string, skyImage: proc(sky, face: string): string) =
  ## The skybox of sky `name` (skyImage finds its faces), rebuilt when the
  ## name changes or its images have just been extracted.
  if name == r.skyName and (name.len == 0 or r.skyMesh.vao != 0): return
  deleteMesh(r.skyMesh)
  r.skyMesh = MeshLayer()
  r.skyName = name
  if name.len == 0 or not fileExists(skyImage(name, SkyFaces[0])): return
  # Cube corners at +-1, UVs as Oni maps them (see sky.nim).
  proc uvOf(face: string, p: Vec3): Vec2 =
    case face
    of "top": vec2((p.x + 1) / 2, (1 - p.z) / 2)
    of "bottom": vec2((p.x + 1) / 2, (p.z + 1) / 2)
    of "right": vec2((p.z + 1) / 2, (1 - p.y) / 2)
    of "left": vec2((1 - p.z) / 2, (1 - p.y) / 2)
    of "back": vec2((1 - p.x) / 2, (1 - p.y) / 2)
    else: vec2((p.x + 1) / 2, (1 - p.y) / 2)
  const corners = {"top": [vec3(-1, 1, -1), vec3(1, 1, -1), vec3(1, 1, 1), vec3(-1, 1, 1)],
                   "right": [vec3(1, -1, -1), vec3(1, 1, -1), vec3(1, 1, 1), vec3(1, -1, 1)],
                   "left": [vec3(-1, -1, -1), vec3(-1, 1, -1), vec3(-1, 1, 1), vec3(-1, -1, 1)],
                   "back": [vec3(-1, -1, 1), vec3(1, -1, 1), vec3(1, 1, 1), vec3(-1, 1, 1)],
                   "front": [vec3(-1, -1, -1), vec3(1, -1, -1), vec3(1, 1, -1), vec3(-1, 1, -1)],
                   "bottom": [vec3(-1, -1, -1), vec3(1, -1, -1), vec3(1, -1, 1), vec3(-1, -1, 1)]}
  const white = [255'u8, 255, 255, 255]
  var data: seq[LevelVert]
  var draws: seq[DrawRange]
  var low: array[3, float32]   # The sides' bottom row: the color of a sky with no bottom face.
  var lowCount = 0
  for (face, k) in corners:
    var tex: GLuint
    var col = white
    let path = skyImage(name, face)
    if face == "bottom" and not fileExists(path):
      if lowCount > 0:
        for c in 0 .. 2: col[c] = uint8(low[c] / lowCount.float32)
    else:
      tex = r.texture(path)[0]
      if tex == 0: continue
      glBindTexture(GL_TEXTURE_2D, tex)   # No seams between the faces.
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE.GLint)
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE.GLint)
      if face notin ["top", "bottom"]:
        try:
          let img = readTga(readFile(path))
          let row = (img.height - 1) * img.width * 4
          for x in 0 ..< img.width:
            for c in 0 .. 2: low[c] += img.rgba[row + x * 4 + c].float32
          lowCount += img.width
        except CatchableError: discard
    let first = data.len
    for i in [0, 1, 2, 0, 2, 3]:
      data.add LevelVert(pos: k[i], uv: uvOf(face, k[i]), col: col)
    draws.add DrawRange(first: first.int32, count: 6, tex: tex)
  r.skyMesh = newMesh(data, draws)

proc clearAll*(r: Renderer) =
  for l in Layer: r.clearLayer(l)
  r.previewKey = ""
  deleteMesh(r.skyMesh)   # Its textures go below.
  r.skyMesh = MeshLayer()
  r.skyName = ""
  r.clearModels()   # Their textures go below.
  for _, (tex, _) in r.textures:
    if tex != 0:
      var t = tex
      glDeleteTextures(1, t.addr)
  r.textures.clear()
  r.brightTextures.clear()
  r.clampedTextures.clear()
  r.geometryVersion = -1

proc fogUniforms(r: Renderer, uOn, uColor, uParams: GLint, on: bool) =
  ## The fog for the draws that follow (the program in use).
  glUniform1i(uOn, (if on: 1 else: 0))
  if on:
    let f = r.fog
    glUniform3f(uColor, f.color.x, f.color.y, f.color.z)
    glUniform4f(uParams, f.start, f.finish, f.near, max(f.far, f.near + 1))

type DrawPass = enum
  dpAll       ## Every draw in its order.
  dpSolid     ## All but the blended ones (textured).
  dpBlended   ## Only the blended ones, farthest first, as Oni's alpha pass.

proc drawMesh(r: Renderer, m: MeshLayer, mvp: M4, tint: Vec4, textured: bool, lit = true,
              grid = false, pass = dpAll) =
  ## grid: TrenchBroom's 3D grid on the faces (r.grid3D; level geometry only).
  if m.vao == 0: return
  glUseProgram(r.levelProg)
  let prim = if m.lines: GL_LINES else: GL_TRIANGLES
  var mm = mvp
  glUniformMatrix4fv(r.uLevelMvp, 1, GL_FALSE, mm[0].addr)
  glUniform1i(r.uLevelTex, 0)
  glUniform1f(r.uLevelLight, (if r.fullbright or not lit: 1'f32 else: 0'f32))
  glUniform1i(r.uLevelShowTint, (if r.fullbright and r.showTint and lit: 1 else: 0))
  glUniform4f(r.uLevelTint, tint.x, tint.y, tint.z, tint.w)
  let showGrid = grid and r.grid3D > 0
  glUniform1i(r.uLevelGrid, (if showGrid: 1 else: 0))
  glUniform1f(r.uLevelGridSize, r.grid3D)
  glUniform1f(r.uLevelGridAlpha, r.gridAlpha)
  glUniform1f(r.uLevelGridThickness, r.gridThickness)
  glUniform1f(r.uLevelBrightness, r.brightness)
  glUniform1i(r.uLevelSkyBlend, (if r.skyPass: r.skyGrade.blend.ord.GLint else: -1))
  glUniform3f(r.uLevelSkyTint, r.skyGrade.tint[0].float32 / 255, r.skyGrade.tint[1].float32 / 255,
              r.skyGrade.tint[2].float32 / 255)
  glUniform1f(r.uLevelSkyGain, r.skyGrade.brightness)
  glUniform1i(r.uLevelFacing, (if r.facing: 1 else: 0))
  glUniform3f(r.uLevelViewDir, r.viewDir.x, r.viewDir.y, r.viewDir.z)
  r.fogUniforms(r.uLevelFog, r.uLevelFogColor, r.uLevelFogParams, r.fogNow and not r.skyPass)
  glActiveTexture(GL_TEXTURE0)
  glBindVertexArray(m.vao)
  var order: seq[int]
  for i, d in m.draws:
    let blended = textured and d.blend
    if pass == dpAll or (pass == dpBlended) == blended: order.add i
  if pass == dpBlended:
    let eye = r.camPos
    order.sort(proc(i, j: int): int =
      cmp((m.draws[j].center - eye).lengthSq, (m.draws[i].center - eye).lengthSq))
  for i in order:
    let d = m.draws[i]
    let useTex = textured and d.tex != 0
    if showGrid:
      if r.gridColor3D:
        glUniform3f(r.uLevelGridColor, r.gridColor.x, r.gridColor.y, r.gridColor.z)
      else:
        let c = if d.gridDark: 0'f32 else: 1'f32
        glUniform3f(r.uLevelGridColor, c, c, c)
    glUniform1i(r.uLevelUseTex, (if useTex: 1 else: 0))
    glUniform1i(r.uLevelAlphaTest, (if useTex and d.alphaTest: 1 else: 0))
    glUniform1i(r.uLevelBlend, (if useTex and d.blend: 1 else: 0))
    if useTex: glBindTexture(GL_TEXTURE_2D, d.tex)
    if r.cullBack and not d.twoSided: glEnable(GL_CULL_FACE) else: glDisable(GL_CULL_FACE)
    glDrawArrays(prim, d.first, d.count)
  glDisable(GL_CULL_FACE)
  glBindVertexArray(0)

proc drawLayer(r: Renderer, layer: Layer, mvp: M4, tint: Vec4, textured: bool, lit = true,
               grid = false, pass = dpAll) =
  r.drawMesh(r.layers[layer], mvp, tint, textured, lit, grid, pass)

proc drawSky(r: Renderer, cam: Camera, w, h: int32) =
  ## The skybox around the camera, behind everything (no depth).
  if r.skyMesh.vao == 0: return
  const s = 1000'f32   # Well inside the far plane at any angle.
  let p = cam.pos
  let m: M4 = [s, 0, 0, 0, 0, s, 0, 0, 0, 0, s, 0, p.x, p.y, p.z, 1]
  glDisable(GL_DEPTH_TEST)
  glDepthMask(GL_FALSE)
  glDisable(GL_BLEND)
  # Lit by its vertex colors: white on the images, the horizon's color below.
  let (grid, bright, brightness) = (r.grid3D, r.fullbright, r.brightness)
  r.grid3D = 0
  r.fullbright = false
  r.brightness = 1
  r.skyPass = true
  r.drawMesh(r.skyMesh, mul(cam.matrix(w.float32, h.float32), m), vec4(1, 1, 1, 1), true)
  r.skyPass = false
  (r.grid3D, r.fullbright, r.brightness) = (grid, bright, brightness)
  glEnable(GL_BLEND)
  glDepthMask(GL_TRUE)

proc normalMatrix(m: M4): array[9, float32] =
  ## The column-major 3x3 that turns m's (column-major 4x4) normals into
  ## world space: the inverse transpose of its 3x3, as cofactors (the same
  ## direction; turned back when m mirrors). The shader normalizes.
  template a(r, c: int): float32 = m[c * 4 + r]
  var cof: array[3, array[3, float32]]   # [row][col]
  for r in 0 .. 2:
    for c in 0 .. 2:
      let (r1, r2) = ((r + 1) mod 3, (r + 2) mod 3)
      let (c1, c2) = ((c + 1) mod 3, (c + 2) mod 3)
      cof[r][c] = a(r1, c1) * a(r2, c2) - a(r1, c2) * a(r2, c1)
  let det = a(0, 0) * cof[0][0] + a(0, 1) * cof[0][1] + a(0, 2) * cof[0][2]
  let sign = if det < 0: -1'f32 else: 1'f32
  for r in 0 .. 2:
    for c in 0 .. 2: result[c * 3 + r] = cof[r][c] * sign

proc drawModels(r: Renderer, mvp: M4, is3D, textured: bool) =
  ## Every model instance: solid in 3D, wireframe in 2D (lit = is3D, as
  ## drawMesh would draw each). The state they share is set once: a level has
  ## hundreds of them.
  if r.modelInstances.len == 0: return
  let lit = is3D
  let textured = is3D and textured
  glUseProgram(r.levelProg)
  glUniform1i(r.uLevelTex, 0)
  glUniform1f(r.uLevelLight, (if r.fullbright or not lit: 1'f32 else: 0'f32))
  glUniform1i(r.uLevelShowTint, (if r.fullbright and r.showTint and lit: 1 else: 0))
  glUniform1i(r.uLevelGrid, 0)
  glUniform1f(r.uLevelGridSize, r.grid3D)
  glUniform1f(r.uLevelGridAlpha, r.gridAlpha)
  glUniform1f(r.uLevelGridThickness, r.gridThickness)
  glUniform1f(r.uLevelBrightness, r.brightness)
  glUniform1i(r.uLevelSkyBlend, -1)
  glUniform1i(r.uLevelFacing, (if r.facing: 1 else: 0))
  glUniform3f(r.uLevelViewDir, r.viewDir.x, r.viewDir.y, r.viewDir.z)
  glUniform1i(r.uLevelBlend, 0)
  r.fogUniforms(r.uLevelFog, r.uLevelFogColor, r.uLevelFogParams, r.fogNow)
  # Lit as Oni lights models, in 3D (2D wireframe ignores vertex colors).
  glUniform1i(r.uOniLit, (if lit: 1 else: 0))
  var dirs = [OniLightDirs[0].x, OniLightDirs[0].y, OniLightDirs[0].z,
              OniLightDirs[1].x, OniLightDirs[1].y, OniLightDirs[1].z]
  var colors = OniLightColors
  glUniform3fv(r.uOniDir, 2, dirs[0].addr)
  glUniform1fv(r.uOniColor, 2, colors[0].addr)
  glUniform1f(r.uOniAmbient, OniAmbient)
  glActiveTexture(GL_TEXTURE0)
  glDisable(GL_CULL_FACE)
  if not is3D: glPolygonMode(GL_FRONT_AND_BACK, GL_LINE)
  var lastUseTex, lastAlpha = -1
  for inst in r.modelInstances:
    let key = r.model(inst.path, inst.base, inst.image)
    let m = r.models[key].addr
    if m.vao == 0: continue
    var full = mul(mvp, inst.transform)
    glUniformMatrix4fv(r.uLevelMvp, 1, GL_FALSE, full[0].addr)
    if lit:
      var nm = normalMatrix(inst.transform)
      glUniformMatrix3fv(r.uNormalMat, 1, GL_FALSE, nm[0].addr)
    if is3D: glUniform4f(r.uLevelTint, inst.tint.x, inst.tint.y, inst.tint.z, inst.tint.w)
    else:
      let c = inst.wire
      glUniform4f(r.uLevelTint, c[0].float32 / 255, c[1].float32 / 255, c[2].float32 / 255, c[3].float32 / 255)
    glBindVertexArray(m.vao)
    for d in m.draws:
      let useTex = textured and d.tex != 0
      let ut = (if useTex: 1 else: 0)
      let at = (if useTex and d.alphaTest: 1 else: 0)
      if ut != lastUseTex:
        glUniform1i(r.uLevelUseTex, ut.GLint)
        lastUseTex = ut
      if at != lastAlpha:
        glUniform1i(r.uLevelAlphaTest, at.GLint)
        lastAlpha = at
      if useTex: glBindTexture(GL_TEXTURE_2D, d.tex)
      glDrawArrays(GL_TRIANGLES, d.first, d.count)
  if not is3D: glPolygonMode(GL_FRONT_AND_BACK, GL_FILL)
  glUniform1i(r.uOniLit, 0)   # The level and the sky share the program.
  glBindVertexArray(0)

proc drawFlat(r: Renderer, verts: seq[FlatVert], mode: GLenum, mvp: M4) =
  if verts.len == 0: return
  glUseProgram(r.flatProg)
  var mm = mvp
  glUniformMatrix4fv(r.uFlatMvp, 1, GL_FALSE, mm[0].addr)
  glBindVertexArray(r.dynVao)
  glBindBuffer(GL_ARRAY_BUFFER, r.dynVbo)
  glBufferData(GL_ARRAY_BUFFER, verts.len * sizeof(FlatVert), verts[0].unsafeAddr, GL_STREAM_DRAW)
  glDrawArrays(mode, 0, verts.len.GLsizei)
  glBindVertexArray(0)

proc depthPass(r: Renderer, mvp: M4, w, h: int32): bool =
  ## Draws the opaque geometry and models into cavityDepth (w x h). Its own
  ## target, not the window's depth: that may be multisampled and can't be read.
  ## Leaves the framebuffer bound as it found it, the viewport to the caller.
  var prev: GLint
  glGetIntegerv(GL_FRAMEBUFFER_BINDING, prev.addr)
  if r.cavitySize != (w, h):
    if r.cavityDepth == 0:
      glGenTextures(1, r.cavityDepth.addr)
      glGenFramebuffers(1, r.cavityFbo.addr)
    glBindTexture(GL_TEXTURE_2D, r.cavityDepth)
    glTexImage2D(GL_TEXTURE_2D, 0, GL_DEPTH_COMPONENT24.GLint, w, h, 0, GL_DEPTH_COMPONENT,
                 GL_UNSIGNED_INT, nil)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST.GLint)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST.GLint)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE.GLint)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE.GLint)
    glBindFramebuffer(GL_FRAMEBUFFER, r.cavityFbo)
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_TEXTURE_2D, r.cavityDepth, 0)
    glDrawBuffer(GL_NONE)
    glReadBuffer(GL_NONE)
    r.cavitySize = (w, h)
  glBindFramebuffer(GL_FRAMEBUFFER, r.cavityFbo)
  result = glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE
  if result:
    glDisable(GL_SCISSOR_TEST)
    glViewport(0, 0, w, h)
    glDepthMask(GL_TRUE)
    glClear(GL_DEPTH_BUFFER_BIT)
    glDisable(GL_BLEND)
    r.cullBack = true
    r.drawLayer(lGeometry, mvp, vec4(1, 1, 1, 1), false)
    r.cullBack = false
    r.drawModels(mvp, true, false)
    glEnable(GL_SCISSOR_TEST)
  glBindFramebuffer(GL_FRAMEBUFFER, prev.GLuint)

proc drawCavity(r: Renderer, cam: Camera, x, glY, w, h: int32) =
  ## Multiplies the view (the current viewport) by the cavity of cavityDepth.
  glUseProgram(r.cavityProg)
  glActiveTexture(GL_TEXTURE0)
  glBindTexture(GL_TEXTURE_2D, r.cavityDepth)
  glUniform1i(r.uCavityDepth, 0)
  glUniform2f(r.uCavityOrigin, x.float32, glY.float32)
  glUniform2f(r.uCavityPixel, 1 / w.float32, 1 / h.float32)
  let t = 1 / tan(cam.fovY / 2)
  glUniform2f(r.uCavityProj, t * h.float32 / max(w, 1).float32, t)
  glUniform2f(r.uCavityNearFar, Near3D, Far3D)
  glDisable(GL_DEPTH_TEST)
  glDepthMask(GL_FALSE)
  glEnable(GL_BLEND)
  glBlendFunc(GL_DST_COLOR, GL_SRC_COLOR)
  glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_FALSE)
  glBindVertexArray(r.cavityVao)
  glDrawArrays(GL_TRIANGLES, 0, 3)
  glBindVertexArray(0)
  glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE)
  glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)
  glDepthMask(GL_TRUE)
  glEnable(GL_DEPTH_TEST)

proc spriteQuad(sp: SpriteInst, camPos, right, up: Vec3): (bool, array[4, Vec3], array[4, Vec2], float32) =
  ## The particle's corners, their texture coordinates and how much edge
  ## fading leaves of it. As the engine draws it: U runs along the sprite's X
  ## (Scale), V along its Y (YScale).
  var x, y: Vec3
  case sp.mode
  of 1:
    # Rotated sprite: facing the camera, its X along the heading on screen.
    var (dx, dy) = (dot(sp.ax[1], right), dot(sp.ax[1], up))
    let d = dx * dx + dy * dy
    if d < 1e-8: (dx, dy) = (1'f32, 0'f32)
    else: (dx, dy) = (dx / sqrt(d), dy / sqrt(d))
    x = right * dx + up * dy
    y = right * dy - up * dx
  of 2:
    # Beam: its X along the heading, turned about it to face the camera.
    x = if sp.ax[1].lengthSq > 1e-8: sp.ax[1] else: vec3(0, 1, 0)
    y = cross(x, sp.pos - camPos)
    if y.length < 1e-6: return
    y = y.normalize
  of 3: (x, y) = (sp.ax[1], sp.ax[2])                # Arrow: along the heading and up.
  of 4: (x, y) = (sp.ax[0], sp.ax[2])                # Flat: across the heading.
  of 7: (x, y) = (sp.ax[1], sp.ax[0])                # Discus: along the heading and to the side.
  of 8: (x, y) = (sp.ax[0], -sp.ax[2])               # Decal: on its surface; drawSprites turns the texture.
  else: (x, y) = (right, up)
  if sp.mode != 8 and sp.rot != 0:
    let a = sp.rot.degToRad
    (x, y) = (x * cos(a) - y * sin(a), x * sin(a) + y * cos(a))
  elif sp.mode == 0: y = -up                         # Unturned sprites have V down the screen.
  var keep = 1'f32
  if sp.edgeFade and sp.perp.lengthSq > 0:
    var c = dot(sp.perp, (camPos - sp.pos).normalize)
    if not sp.oneSided: c = abs(c)
    if sp.mode == 2: c = 1 - c
    if c < sp.edgeMin: return
    if c < sp.edgeMax and sp.edgeMax > sp.edgeMin: keep = (c - sp.edgeMin) / (sp.edgeMax - sp.edgeMin)
  let (x0, x1) = ((1 - sp.xShorten) * (sp.xOffset - 1), (1 - sp.xShorten) * (sp.xOffset + 1))
  let (u0, u1) = (-0.5'f32 * sp.xShorten * (sp.xOffset - 1), 1 - 0.5'f32 * sp.xShorten * (sp.xOffset + 1))
  let (hx, hy) = (x * sp.scale, y * sp.yscale)
  (true, [sp.pos + hx * x0 - hy, sp.pos + hx * x1 - hy, sp.pos + hx * x1 + hy, sp.pos + hx * x0 + hy],
   [vec2(u0, 0), vec2(u1, 0), vec2(u1, 1), vec2(u0, 1)], keep)

proc spriteTexture(r: Renderer, path: string): GLuint =
  let (tex, _) = r.texture(path)
  if tex != 0 and tex notin r.clampedTextures:
    glBindTexture(GL_TEXTURE_2D, tex)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE.GLint)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE.GLint)
    r.clampedTextures.incl tex
  tex

proc drawSprites(r: Renderer, cam: Camera, mvp: M4) =
  ## Realtime preview's particles: decals on the walls, then the rest behind
  ## to front (additive ones after), then lens flares over everything.
  ## Contrail and model triangles sort with the sprites.
  if r.sprites.len == 0 and r.particleTris.len == 0: return
  let fwd = cam.forward
  let right = fwd.cross(vec3(0, 1, 0)).normalize
  let up = right.cross(fwd)
  let ns = r.sprites.len
  let total = ns + r.particleTris.len
  var order = newSeq[int](total)   # Below ns: a sprite; from ns: a triangle.
  var dist = newSeq[float32](total)
  var passOf = newSeq[int](total)
  for i, sp in r.sprites:
    order[i] = i
    dist[i] = (sp.pos - cam.pos).length
    passOf[i] = if sp.mode == 8: 0 elif sp.flare: 3 elif sp.additive: 2 else: 1
  for i, t in r.particleTris:
    order[ns + i] = ns + i
    dist[ns + i] = ((t.p[0] + t.p[1] + t.p[2]) / 3 - cam.pos).length
    passOf[ns + i] = if t.additive: 2 else: 1
  order.sort(proc(a, b: int): int =
    result = cmp(passOf[a], passOf[b])
    if result == 0: result = cmp(dist[b], dist[a]))
  glUseProgram(r.spriteProg)
  var mm = mvp
  glUniformMatrix4fv(r.uSpriteMvp, 1, GL_FALSE, mm[0].addr)
  glUniform1i(r.uSpriteTex, 0)
  # Lens flares, sky particles and additive textures are drawn unfogged in the
  # game: Oni turns GL fog off for any texture with the additive flag
  # (0x40d6d8, Bungie's gl_set_textures "force fog off!"), else the black of
  # an additive texture would add the fog color and show the whole quad.
  var curFog = r.fogNow
  r.fogUniforms(r.uSpriteFog, r.uSpriteFogColor, r.uSpriteFogParams, curFog)
  glActiveTexture(GL_TEXTURE0)
  glBindVertexArray(r.spriteVao)
  glBindBuffer(GL_ARRAY_BUFFER, r.spriteVbo)
  glDepthMask(GL_FALSE)
  var verts: seq[SpriteVert]
  var curTex = 0.GLuint
  var curPass = -1
  proc flush() =
    if verts.len == 0: return
    glBindTexture(GL_TEXTURE_2D, curTex)
    glBufferData(GL_ARRAY_BUFFER, verts.len * sizeof(SpriteVert), verts[0].addr, GL_STREAM_DRAW)
    glDrawArrays(GL_TRIANGLES, 0, verts.len.GLsizei)
    verts.setLen 0
  proc use(ps: int, tex: GLuint, additive: bool, fogged: bool) =
    let fogOn = r.fogNow and fogged
    if fogOn != curFog:
      flush()
      curFog = fogOn
      r.fogUniforms(r.uSpriteFog, r.uSpriteFogColor, r.uSpriteFogParams, curFog)
    if ps != curPass or tex != curTex:
      flush()
      if ps != curPass:
        curPass = ps
        if ps == 0:
          glEnable(GL_POLYGON_OFFSET_FILL)
          glPolygonOffset(-2, -2)
        else: glDisable(GL_POLYGON_OFFSET_FILL)
        if ps == 3: glDisable(GL_DEPTH_TEST) else: glEnable(GL_DEPTH_TEST)
      glBlendFunc(GL_SRC_ALPHA, if additive: GL_ONE else: GL_ONE_MINUS_SRC_ALPHA)
      curTex = tex
  for i in order:
    let ps = passOf[i]
    if i >= ns:
      let t = r.particleTris[i - ns]
      let tex = if t.wrap: r.texture(t.tex)[0] else: r.spriteTexture(t.tex)
      if tex == 0: continue
      use(ps, tex, t.additive, not (t.sky or t.additive))
      for k in 0 .. 2: verts.add SpriteVert(pos: t.p[k], uv: t.uv[k], col: t.col[k])
      continue
    let sp = r.sprites[i]
    let tex = r.spriteTexture(sp.tex)
    if tex == 0: continue
    var (ok, c, uvs, keep) = spriteQuad(sp, cam.pos, right, up)
    if not ok: continue
    use(ps, tex, sp.additive, not (sp.flare or sp.sky or sp.additive))
    var col = sp.col
    col[3] = uint8(col[3].float32 * keep)
    if sp.mode == 8:
      let k = ((int(round(sp.rot / 90)) mod 4) + 4) mod 4
      for j in 0 ..< k: uvs = [uvs[3], uvs[0], uvs[1], uvs[2]]
    for j in [0, 1, 2, 0, 2, 3]:
      verts.add SpriteVert(pos: c[j], uv: uvs[j], col: col)
  flush()
  glDisable(GL_POLYGON_OFFSET_FILL)
  glEnable(GL_DEPTH_TEST)
  glDepthMask(GL_TRUE)
  glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)
  glBindVertexArray(0)

proc arrowTris(r: Renderer, cam: Camera, h: float32, onTop: bool): seq[FlatVert] =
  ## The arrows for this view, facing it: the translation gizmo's shape
  ## (viewtools drawViewOverlays) at a fixed size on screen, kept within a sane
  ## size in the world, so they stand in the level and don't pile up zoomed out.
  const (arrowPx, headLen, headHalf, shaftHalf) = (44'f32, 12'f32, 5'f32, 1'f32)
  let is3D = cam.kind == vk3D
  for ar in r.arrows:
    if ar.onTop != onTop: continue
    let scale = if is3D: 2 * max((ar.base - cam.pos).dot(cam.forward), 1) * tan(cam.fovY / 2) / max(h, 1)
                else: 1 / max(cam.zoom, 1e-4)
    let px = (if is3D: clamp(arrowPx * scale, 14, 60) else: min(arrowPx * scale, 24)) / arrowPx
    let view = if is3D: (ar.base - cam.pos) else: -cam.kind.axes.toViewer
    var side = ar.dir.cross(view)
    if side.length < 1e-4: side = ar.dir.cross(if abs(ar.dir.y) < 0.9: vec3(0, 1, 0) else: vec3(1, 0, 0))
    side = side.normalize
    let tip = ar.base + ar.dir * arrowPx * px
    let neck = tip - ar.dir * headLen * px
    let (s, hw) = (side * shaftHalf * px, side * headHalf * px)
    for p in [ar.base - s, ar.base + s, neck + s, ar.base - s, neck + s, neck - s,
              tip, neck - hw, neck + hw]:
      result.add FlatVert(pos: p, col: ar.col)

proc drawCompass(r: Renderer, cam: Camera, x, glY: int32) =
  ## Axis gizmo: X red, Y (up) green, Z blue.
  const size = 64'i32
  glViewport(x, glY, size, size)
  glScissor(x, glY, size, size)
  var view: M4
  if cam.kind == vk3D:
    let f = cam.forward
    let s = f.cross(vec3(0, 1, 0)).normalize
    let u = s.cross(f)
    view = [s.x, u.x, -f.x, 0, s.y, u.y, -f.y, 0, s.z, u.z, -f.z, 0, 0, 0, 0, 1]
  else:
    let a = cam.kind.axes
    view = [a.right.x, a.up.x, a.toViewer.x, 0, a.right.y, a.up.y, a.toViewer.y, 0,
            a.right.z, a.up.z, a.toViewer.z, 0, 0, 0, 0, 1]
  const k = 1'f32 / 1.4'f32
  let proj: M4 = [k, 0, 0, 0, 0, k, 0, 0, 0, 0, -0.5'f32, 0, 0, 0, 0, 1]
  var v: seq[FlatVert]
  for (axis, col) in [(vec3(1, 0, 0), [235'u8, 80, 70, 255]), (vec3(0, 1, 0), [110'u8, 210, 90, 255]),
                      (vec3(0, 0, 1), [80'u8, 140, 255, 255])]:
    v.add FlatVert(pos: vec3(0, 0, 0), col: col)
    v.add FlatVert(pos: axis, col: col)
  r.drawFlat(v, GL_LINES, mul(proj, view))

proc drawView*(r: Renderer, cam: Camera, x, y, w, h: int32, fbHeight: int32,
               bg: Vec4, opts: ViewOptions) =
  ## Renders one map view. (x, y) is the top-left corner in framebuffer pixels.
  let glY = fbHeight - y - h
  glViewport(x, glY, w, h)
  glEnable(GL_SCISSOR_TEST)
  glScissor(x, glY, w, h)
  glClearColor(bg.x, bg.y, bg.z, bg.w)
  glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT)
  let mvp = cam.matrix(w.float32, h.float32)
  let is3D = cam.kind == vk3D
  glDisable(GL_CULL_FACE)
  glEnable(GL_BLEND)
  glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)

  let mode = if is3D: opts.mode else: rmWireframe
  let (textured, wire) = (mode.textured, mode.wireframe)
  r.fullbright = mode in {rmUnlit, rmSolid}
  r.showTint = mode == rmUnlit
  # Realtime preview's fog, in the textured modes: on what the game fogs (the
  # level, objects, particles), not the sky or what only the editor draws.
  let fogged = is3D and textured and r.fog.on
  proc wireLayer(tris, edges: Layer, tint: Vec4, lit: bool) =
    ## A layer's wireframe: its triangles, or its face outlines (showTriangles off).
    if r.showTriangles:
      glPolygonMode(GL_FRONT_AND_BACK, GL_LINE)
      r.drawLayer(tris, mvp, tint, false, lit = lit)
      glPolygonMode(GL_FRONT_AND_BACK, GL_FILL)
    else:
      r.drawLayer(edges, mvp, tint, false, lit = lit)

  if not is3D and r.gridLines.len > 0:
    glDisable(GL_DEPTH_TEST)
    r.drawFlat(r.gridLines, GL_TRIANGLES, mvp)
  if is3D and opts.sky and textured:
    r.drawSky(cam, w, h)
  glEnable(GL_DEPTH_TEST)
  glDepthFunc(GL_LEQUAL)
  glDepthMask(GL_TRUE)

  if not wire:
    glDisable(GL_BLEND)
    glEnable(GL_POLYGON_OFFSET_FILL)
    glPolygonOffset(1, 1)
    # As in Oni (and TrenchBroom): back faces are culled unless Two-sided, so
    # touching brushes' coincident opposite faces don't z-fight.
    r.cullBack = is3D
    r.facing = mode == rmSolid
    r.viewDir = cam.forward
    r.camPos = cam.pos
    r.fogNow = fogged
    r.drawLayer(lGeometry, mvp, vec4(1, 1, 1, 1), textured, grid = true, pass = dpSolid)
    r.fogNow = false
    r.facing = false
    r.cullBack = false
    glDisable(GL_POLYGON_OFFSET_FILL)
    glEnable(GL_BLEND)
  else:
    if not is3D: glDisable(GL_DEPTH_TEST)
    if mode == rmLitWireframe:
      wireLayer(lGeometry, lGeometryEdges, vec4(1, 1, 1, 1), true)
    else:
      wireLayer(lGeometry, lGeometryEdges,
                (if is3D: vec4(0.75, 0.8, 0.9, 1) else: vec4(0.5, 0.53, 0.6, 1)), false)
    glEnable(GL_DEPTH_TEST)

  if opts.models and r.modelInstances.len > 0:
    if not wire:
      glDisable(GL_BLEND)
      r.fogNow = fogged
      r.drawModels(mvp, true, textured)
      r.fogNow = false
      glEnable(GL_BLEND)
    else:
      if not is3D: glDisable(GL_DEPTH_TEST)
      r.drawModels(mvp, false, false)
      glEnable(GL_DEPTH_TEST)

  if not wire:
    # Oni's alpha pass: see-through textures after everything solid, farthest
    # first, both sides, without writing depth (M3rGeom_Draw_Environment_Alpha).
    glEnable(GL_BLEND)
    glDepthMask(GL_FALSE)
    glEnable(GL_POLYGON_OFFSET_FILL)
    glPolygonOffset(1, 1)
    r.facing = mode == rmSolid
    r.viewDir = cam.forward
    r.fogNow = fogged
    r.drawLayer(lGeometry, mvp, vec4(1, 1, 1, 1), textured, grid = true, pass = dpBlended)
    r.fogNow = false
    r.facing = false
    glDisable(GL_POLYGON_OFFSET_FILL)
    glDepthMask(GL_TRUE)

  if mode == rmSolid:
    # After the opaque things, before what's see-through.
    if r.depthPass(mvp, w, h):
      glViewport(x, glY, w, h)
      r.drawCavity(cam, x, glY, w, h)
    else:
      glViewport(x, glY, w, h)
    glEnable(GL_BLEND)
    glEnable(GL_DEPTH_TEST)
    glDepthMask(GL_TRUE)

  if is3D and not wire:
    r.fogNow = fogged
    r.drawSprites(cam, mvp)
    r.fogNow = false

  if not wire and r.layers[lPreview].vao != 0:
    # Brushes being created: textured and see-through (their edges are overlay lines).
    r.drawLayer(lPreview, mvp, PreviewTint, textured, grid = true)

  glDepthMask(GL_FALSE)
  if not wire:
    r.drawLayer(lInvisible, mvp, InvisibleTint, false, lit = false, grid = true)
  else:
    wireLayer(lInvisible, lInvisibleEdges, vec4(InvisibleTint.xyz, 0.7), false)
  if opts.markers:
    if not wire:
      r.drawLayer(lMarkers, mvp, vec4(1.0, 0.55, 0.15, 0.30), false, lit = false, grid = true)
    else:
      wireLayer(lMarkers, lMarkerEdges, vec4(1.0, 0.55, 0.15, 0.6), false)
  if opts.rooms:
    r.drawLayer(lRooms, mvp, vec4(0.3, 0.8, 1.0, 0.16), false, lit = false)
  if not is3D: glDisable(GL_DEPTH_TEST)
  r.drawFlat(r.tris, GL_TRIANGLES, mvp)
  glDepthMask(GL_TRUE)
  r.drawFlat(r.lines, GL_LINES, mvp)
  r.drawFlat(r.arrowTris(cam, h.float32, false), GL_TRIANGLES, mvp)
  glDisable(GL_DEPTH_TEST)
  r.drawFlat(r.overlayTris, GL_TRIANGLES, mvp)
  r.drawFlat(r.overlayLines, GL_LINES, mvp)
  r.drawFlat(r.arrowTris(cam, h.float32, true), GL_TRIANGLES, mvp)

  r.drawCompass(cam, x + 6, glY + 6)
  glDisable(GL_SCISSOR_TEST)
  glDisable(GL_DEPTH_TEST)
  glUseProgram(0)

proc textureLuma*(r: Renderer, path: string): float32 =
  ## Luma of a texture's average color (0..1), loading it if need be; 0 when it can't be.
  discard r.texture(path)
  r.textureLumas.getOrDefault(path, 0)

proc drawUvTexture*(r: Renderer, path: string, view, clip: tuple[x, y, w, h: int32],
                    uvs: array[4, Vec2], back: Vec3): bool =
  ## Fills view (GL pixels, origin bottom left) with the texture, clipped to
  ## clip. uvs are its corners' texture coordinates: bottom left, bottom
  ## right, top right, top left. False when the texture can't be loaded.
  let (tex, _) = r.texture(path)
  if tex == 0 or view.w <= 0 or view.h <= 0 or clip.w <= 0 or clip.h <= 0: return false
  if r.uvProg == 0:
    r.uvProg = link(uvVs, uvFs)
    r.uUvTex = glGetUniformLocation(r.uvProg, "uTex")
    r.uUvBrightness = glGetUniformLocation(r.uvProg, "uBrightness")
    r.uUvBack = glGetUniformLocation(r.uvProg, "uBack")
    glGenVertexArrays(1, r.uvVao.addr)
    glGenBuffers(1, r.uvVbo.addr)
    glBindVertexArray(r.uvVao)
    glBindBuffer(GL_ARRAY_BUFFER, r.uvVbo)
    glEnableVertexAttribArray(0)
    glVertexAttribPointer(0, 2, cGL_FLOAT, GL_FALSE, 16, nil)
    glEnableVertexAttribArray(1)
    glVertexAttribPointer(1, 2, cGL_FLOAT, GL_FALSE, 16, cast[pointer](8))
    glBindVertexArray(0)
  let corners = [vec2(-1, -1), vec2(1, -1), vec2(1, 1), vec2(-1, 1)]
  var data: array[16, float32]
  for k in 0 .. 3:
    data[k * 4] = corners[k].x
    data[k * 4 + 1] = corners[k].y
    data[k * 4 + 2] = uvs[k].x
    data[k * 4 + 3] = uvs[k].y
  glViewport(view.x, view.y, view.w, view.h)
  glEnable(GL_SCISSOR_TEST)
  glScissor(clip.x, clip.y, clip.w, clip.h)
  glDisable(GL_DEPTH_TEST)
  glDisable(GL_CULL_FACE)
  glDisable(GL_BLEND)
  glUseProgram(r.uvProg)
  glActiveTexture(GL_TEXTURE0)
  glBindTexture(GL_TEXTURE_2D, tex)
  glUniform1i(r.uUvTex, 0)
  glUniform1f(r.uUvBrightness, r.brightness)
  glUniform3f(r.uUvBack, back.x, back.y, back.z)
  glBindVertexArray(r.uvVao)
  glBindBuffer(GL_ARRAY_BUFFER, r.uvVbo)
  glBufferData(GL_ARRAY_BUFFER, sizeof(data), data[0].addr, GL_STREAM_DRAW)
  glDrawArrays(GL_TRIANGLE_FAN, 0, 4)
  glBindVertexArray(0)
  glUseProgram(0)
  glBindTexture(GL_TEXTURE_2D, 0)
  glDisable(GL_SCISSOR_TEST)
  true

proc endViews*(fbWidth, fbHeight: int32) =
  ## Restores the state the UI drawer expects.
  glViewport(0, 0, fbWidth, fbHeight)
  glDisable(GL_SCISSOR_TEST)
  glDisable(GL_DEPTH_TEST)
  glDepthMask(GL_TRUE)
  glEnable(GL_BLEND)
  glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA)

# --- line helpers ---------------------------------------------------------------

proc rgba*(r, g, b: int, a = 255): array[4, uint8] = [r.uint8, g.uint8, b.uint8, a.uint8]

proc line*(buf: var seq[FlatVert], a, b: Vec3, col: array[4, uint8]) =
  buf.add FlatVert(pos: a, col: col)
  buf.add FlatVert(pos: b, col: col)

proc boxCorners*(center, half: Vec3, yawDeg: float32): array[8, Vec3] =
  let a = yawDeg.float64.degToRad
  let (c, s) = (cos(a).float32, sin(a).float32)
  var i = 0
  for dx in [-1'f32, 1]:
    for dy in [-1'f32, 1]:
      for dz in [-1'f32, 1]:
        let lx = dx * half.x
        let lz = dz * half.z
        result[i] = center + vec3(lx * c + lz * s, dy * half.y, -lx * s + lz * c)
        inc i

proc wireBox*(buf: var seq[FlatVert], corners: array[8, Vec3], col: array[4, uint8]) =
  const edges = [(0, 1), (2, 3), (4, 5), (6, 7), (0, 2), (1, 3), (4, 6), (5, 7),
                 (0, 4), (1, 5), (2, 6), (3, 7)]
  for (a, b) in edges: buf.line(corners[a], corners[b], col)

proc solidBox*(buf: var seq[FlatVert], k: array[8, Vec3], col: array[4, uint8]) =
  const faces = [[0, 1, 3, 2], [4, 6, 7, 5], [0, 4, 5, 1], [2, 3, 7, 6], [0, 2, 6, 4], [1, 5, 7, 3]]
  for f in faces:
    for i in [0, 1, 2, 0, 2, 3]:
      buf.add FlatVert(pos: k[f[i]], col: col)

proc wireSphere*(buf: var seq[FlatVert], center: Vec3, radius: float32, col: array[4, uint8]) =
  ## Three great circles, one per axis plane.
  const n = 48
  for axis in 0 .. 2:
    var prev: Vec3
    for i in 0 .. n:
      let t = i.float32 / n * 2 * PI.float32
      let (c, s) = (cos(t) * radius, sin(t) * radius)
      let p = center + (case axis
        of 0: vec3(c, s, 0)
        of 1: vec3(c, 0, s)
        else: vec3(0, c, s))
      if i > 0: buf.line(prev, p, col)
      prev = p

proc solidSphere*(buf: var seq[FlatVert], center: Vec3, radius: float32, col: array[4, uint8]) =
  ## A filled ball (a UV sphere of triangles).
  const (rings, segs) = (8, 16)
  proc at(i, j: int): Vec3 =
    let th = i.float32 / rings.float32 * PI.float32
    let ph = j.float32 / segs.float32 * 2 * PI.float32
    center + vec3(sin(th) * cos(ph), cos(th), sin(th) * sin(ph)) * radius
  for i in 0 ..< rings:
    for j in 0 ..< segs:
      let (a, b, c, d) = (at(i, j), at(i + 1, j), at(i + 1, j + 1), at(i, j + 1))
      for p in [a, b, c, a, c, d]: buf.add FlatVert(pos: p, col: col)

const
  SunBall* = 3.5'f32   ## Radius of the sun gizmo's ball (also what picks the light).
  SpotBall* = 2'f32    ## Radius of the spot gizmo's ball.
  PointBall* = 2'f32   ## Radius of a point light's ball.

proc sunGizmo*(buf: var seq[FlatVert], center: Vec3, col: array[4, uint8]) =
  ## A directional light: a sun (a ball with rays all around). Its direction
  ## is an arrow like any entity's (Renderer.arrows).
  buf.wireSphere(center, SunBall, col)
  for x in -1 .. 1:
    for y in -1 .. 1:
      for z in -1 .. 1:
        if x == 0 and y == 0 and z == 0: continue
        let d = vec3(x.float32, y.float32, z.float32).normalize
        buf.line(center + d * 5, center + d * 7.5, col)

proc spotGizmo*(buf: var seq[FlatVert], center, dir: Vec3, halfAngle, length: float32,
                col: array[4, uint8]) =
  ## A spot light: a small ball and the cone its light fills, length long
  ## (lines from the tip to a ring, plus the ring where the fade begins).
  buf.wireSphere(center, SpotBall, col)
  let side = (if abs(dir.y) < 0.9: cross(dir, vec3(0, 1, 0)) else: cross(dir, vec3(1, 0, 0))).normalize
  let up = cross(side, dir)
  let a = halfAngle.degToRad
  let (r, d) = (sin(a) * length, cos(a) * length)
  const n = 32
  var prev: Vec3
  for i in 0 .. n:
    let t = i.float32 / n * 2 * PI.float32
    let p = center + dir * d + (side * cos(t) + up * sin(t)) * r
    if i > 0: buf.line(prev, p, col)
    if i mod 8 == 0: buf.line(center, p, col)
    prev = p

proc faceFill*(buf: var seq[FlatVert], g: Geometry, f: Face, col: array[4, uint8]) =
  for k in 1 ..< f.verts.len - 1:
    for c in [0, k, k + 1]:
      buf.add FlatVert(pos: g.points[f.verts[c]], col: col)

proc faceOutline*(buf: var seq[FlatVert], g: Geometry, f: Face, col: array[4, uint8]) =
  for k in 0 ..< f.verts.len:
    buf.line(g.points[f.verts[k]], g.points[f.verts[(k + 1) mod f.verts.len]], col)
