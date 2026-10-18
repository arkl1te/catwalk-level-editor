## OpenGL drawing for the map views: the level geometry (textured, lit by its
## baked vertex colors), invisible/marker faces and AI rooms as optional
## overlays, per-frame line and triangle lists for objects, selection, grids and
## tool feedback, and the axis compass in each view's corner.

import std/[tables, os, math]
import opengl, vmath
import collada, tga, camera, geometry, thumbs, sky

type
  FlatVert* = object
    pos*: Vec3
    col*: array[4, uint8]

  LevelVert = object
    pos: Vec3
    uv: Vec2
    col: array[4, uint8]
    nrm: Vec3                      ## Face normal (level geometry only; picks the grid's plane).

  DrawRange = object
    first, count: int32
    tex: GLuint
    alphaTest: bool
    gridDark: bool                 ## Black 3D grid lines (bright texture), else white.

  Layer* = enum lGeometry, lInvisible, lRooms

  ModelInstance* = object
    path*: string                  ## Saved model (thumbs.saveModel).
    base*: string                  ## The folder its image names are relative to.
    transform*: M4
    tint*: Vec4                    ## Solid in 3D.
    wire*: array[4, uint8]         ## Wireframe color in 2D.

  MeshLayer = object
    vao, vbo: GLuint
    draws: seq[DrawRange]

  Renderer* = ref object
    levelProg, flatProg: GLuint
    uLevelMvp, uLevelTex, uLevelUseTex, uLevelLight, uLevelTint, uLevelAlphaTest: GLint
    uLevelGrid, uLevelGridSize, uLevelGridColor: GLint
    uFlatMvp: GLint
    layers: array[Layer, MeshLayer]
    models: Table[string, MeshLayer]   ## Model path -> uploaded mesh (empty if unreadable).
    modelInstances*: seq[ModelInstance]  ## Per frame: models to draw.
    textures: Table[string, (GLuint, bool)]   ## path -> (texture, has alpha)
    brightTextures: Table[string, bool]       ## path -> TrenchBroom's "bright material" test
    modelTextures: seq[string]     ## Texture paths the uploaded models use.
    dynVao, dynVbo: GLuint
    lines*: seq[FlatVert]          ## Depth-tested lines (object boxes).
    tris*: seq[FlatVert]           ## Translucent fills (selection), no depth write.
    overlayLines*: seq[FlatVert]   ## Drawn on top (selection outlines, tool feedback).
    gridLines*: seq[FlatVert]      ## Per 2D view; drawn behind everything.
    fullbright*: bool
    grid3D*: float32               ## Grid size drawn on 3D faces; 0 = hidden.
    geometryVersion*: int          ## Geometry.version last uploaded.
    skyName: string                ## Sky the skybox mesh shows ("" = none).
    skyMesh: MeshLayer             ## Cube around the 3D camera (setSky).

  ViewOptions* = object
    textured*, wireframe*, rooms*, markers*: bool
    models*: bool                  ## Entity models at their objects.
    sky*: bool                     ## The level's skybox behind the 3D view.

const
  levelVs = """
#version 410 core
layout(location = 0) in vec3 aPos;
layout(location = 1) in vec2 aUv;
layout(location = 2) in vec4 aCol;
layout(location = 3) in vec3 aNrm;
uniform mat4 uMvp;
out vec2 vUv;
out vec4 vCol;
out vec3 vPos;
out vec3 vNrm;
void main() {
  gl_Position = uMvp * vec4(aPos, 1.0);
  vUv = aUv;
  vCol = aCol;
  vPos = aPos;
  vNrm = aNrm;
}
"""
  levelFs = """
#version 410 core
in vec2 vUv;
in vec4 vCol;
in vec3 vPos;
in vec3 vNrm;
uniform sampler2D uTex;
uniform int uUseTex;
uniform int uAlphaTest;
uniform float uLight;
uniform vec4 uTint;
uniform int uGrid;
uniform float uGridSize;
uniform vec3 uGridColor;
out vec4 fragColor;

// The 3D face grid of TrenchBroom 2025.4 (Face.fragsh + Grid.fragsh), with
// master's line width cap (see grid()): a major line every 64 units, and finer grids fading into the next coarser one
// where they would alias.
const float GridAlpha = 0.5;   // TrenchBroom's default render/Grid/Alpha.

float softStripes(float value, float ratio, float stripeSize) {
  float mainVal = value * ratio;
  float edge = fwidth(value) * ratio * 2.0;
  float mValue = 1.0 / (64.0 * ratio);
  float triMajor = abs(2.0 * fract(mainVal * mValue) - 1.0);
  float isMajor = step(1.0 - mValue, triMajor);
  float intensity = isMajor * 0.7 + 0.85;
  float triangle = abs(2.0 * fract(mainVal) - 1.0);
  return smoothstep(stripeSize - edge, stripeSize + edge, triangle) * intensity;
}

float gridLines(vec2 c, float ratio, float ratio2, float lineWidth, float blend) {
  float s = 1.0 - lineWidth * ratio;
  float s2 = 1.0 - lineWidth * ratio2;
  float g = max(softStripes(c.x, ratio, s), softStripes(c.y, ratio, s));
  float g2 = max(softStripes(c.x, ratio2, s2), softStripes(c.y, ratio2, s2));
  return mix(g, g2, blend) * 0.5;
}

float grid(vec3 p, vec3 n) {
  float pixelWorld = max(length(dFdx(p)), length(dFdy(p)));
  float minGridSize = 2.0 * pixelWorld;
  // 2025.4 draws lines a fixed 0.5 units wide, which is a few pixels at Quake
  // scale but several times that at Oni's (the camera sits much closer in
  // world units). TrenchBroom master caps the width at a constant on-screen
  // size (Face.fragsh lineWidthFactor); that cap keeps lines as thin as
  // TrenchBroom's.
  float lineWidthFactor = min(4.0 * pixelWorld, 1.0);
  float lineWidth = (uGridSize < 1.0 ? 1.0 / 32.0 : (uGridSize < 4.0 ? 0.25 : 0.5)) * lineWidthFactor;
  float minToRender = minGridSize * 2.0;
  float base = exp2(floor(log2(minToRender)));
  if (uGridSize > base) base = uGridSize;
  float next = 2.0 * base;
  float blend = smoothstep(base, next, minToRender);
  vec3 a = abs(n);
  vec2 c;
  if (a.x > a.y) c = a.x > a.z ? p.yz : p.xy;
  else c = a.y > a.z ? p.xz : p.xy;
  return gridLines(c, 1.0 / base, 1.0 / next, lineWidth, blend);
}

void main() {
  vec4 t = uUseTex == 1 ? texture(uTex, vUv) : vec4(1.0);
  if (uAlphaTest == 1 && t.a < 0.5) discard;
  vec3 lit = mix(vCol.rgb, vec3(1.0), uLight);
  fragColor = vec4(t.rgb * lit, 1.0) * uTint;
  if (uGrid == 1)
    fragColor.rgb = mix(fragColor.rgb, uGridColor, grid(vPos, vNrm) * GridAlpha);
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

proc newRenderer*(): Renderer =
  result = Renderer(geometryVersion: -1)
  result.levelProg = link(levelVs, levelFs)
  result.uLevelMvp = glGetUniformLocation(result.levelProg, "uMvp")
  result.uLevelTex = glGetUniformLocation(result.levelProg, "uTex")
  result.uLevelUseTex = glGetUniformLocation(result.levelProg, "uUseTex")
  result.uLevelLight = glGetUniformLocation(result.levelProg, "uLight")
  result.uLevelTint = glGetUniformLocation(result.levelProg, "uTint")
  result.uLevelAlphaTest = glGetUniformLocation(result.levelProg, "uAlphaTest")
  result.uLevelGrid = glGetUniformLocation(result.levelProg, "uGrid")
  result.uLevelGridSize = glGetUniformLocation(result.levelProg, "uGridSize")
  result.uLevelGridColor = glGetUniformLocation(result.levelProg, "uGridColor")
  result.flatProg = link(flatVs, flatFs)
  result.uFlatMvp = glGetUniformLocation(result.flatProg, "uMvp")
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
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR_MIPMAP_LINEAR.GLint)
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR.GLint)
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_REPEAT.GLint)
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_REPEAT.GLint)
      var alpha = false
      var i = 3
      while i < img.rgba.len:
        if img.rgba[i] < 250:
          alpha = true
          break
        i += 4
      result = (tex, alpha)
      r.brightTextures[path] = isBrightForGrid(img.rgba)
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

proc newMesh(data: seq[LevelVert], draws: seq[DrawRange]): MeshLayer =
  var m = MeshLayer(draws: draws)
  if data.len > 0:
    glGenVertexArrays(1, m.vao.addr)
    glGenBuffers(1, m.vbo.addr)
    glBindVertexArray(m.vao)
    glBindBuffer(GL_ARRAY_BUFFER, m.vbo)
    glBufferData(GL_ARRAY_BUFFER, data.len * sizeof(LevelVert), data[0].unsafeAddr, GL_STATIC_DRAW)
    let stride = sizeof(LevelVert).GLsizei
    glEnableVertexAttribArray(0)
    glVertexAttribPointer(0, 3, cGL_FLOAT, GL_FALSE, stride, nil)
    glEnableVertexAttribArray(1)
    glVertexAttribPointer(1, 2, cGL_FLOAT, GL_FALSE, stride, cast[pointer](12))
    glEnableVertexAttribArray(2)
    glVertexAttribPointer(2, 4, GL_UNSIGNED_BYTE, GL_TRUE, stride, cast[pointer](20))
    glEnableVertexAttribArray(3)
    glVertexAttribPointer(3, 3, cGL_FLOAT, GL_FALSE, stride, cast[pointer](24))
    glBindVertexArray(0)
  m

proc upload(r: Renderer, layer: Layer, data: seq[LevelVert], draws: seq[DrawRange]) =
  r.clearLayer(layer)
  r.layers[layer] = newMesh(data, draws)

proc isMarkerFace*(f: Face): bool =
  (f.flags and (gfInvisible or gfGhost or gfDoorFrame)) != 0 or
    (f.texture.len > 0 and f.texture[0] == '_')

proc setGeometry*(r: Renderer, g: Geometry, texturePath: proc(name: string): string,
                  hidden: proc(fi: int): bool) =
  ## Uploads the editable geometry: visible faces batched per texture, and
  ## invisible/marker faces into their own layer.
  var byTex: OrderedTable[string, seq[int]]
  var marks: seq[int]
  for i, f in g.faces:
    if f.verts.len < 3 or hidden(i): continue
    if f.isMarkerFace: marks.add i
    else: byTex.mgetOrPut(f.texture, @[]).add i
  proc emit(data: var seq[LevelVert], f: Face) =
    let n = g.normal(f)
    for k in 1 ..< f.verts.len - 1:
      for c in [0, k, k + 1]:
        data.add LevelVert(pos: g.points[f.verts[c]], uv: f.uvs[c], col: f.colors[c], nrm: n)
  var data: seq[LevelVert]
  var draws: seq[DrawRange]
  for tex, faces in byTex:
    let first = data.len
    for fi in faces: data.emit(g.faces[fi])
    let path = texturePath(tex)
    let (t, alpha) = r.texture(path)
    draws.add DrawRange(first: first.int32, count: int32(data.len - first), tex: t, alphaTest: alpha,
                        gridDark: r.brightTextures.getOrDefault(path))
  r.upload(lGeometry, data, draws)
  var mdata: seq[LevelVert]
  for fi in marks: mdata.emit(g.faces[fi])
  r.upload(lInvisible, mdata, @[DrawRange(first: 0, count: mdata.len.int32)])
  r.geometryVersion = g.version

proc setRooms*(r: Renderer, scene: DaeScene) =
  var data: seq[LevelVert]
  for b in scene.batches:
    for v in b.verts: data.add LevelVert(pos: v.pos, uv: v.uv, col: v.color)
  r.upload(lRooms, data, @[DrawRange(first: 0, count: data.len.int32)])

proc model(r: Renderer, path, base: string): MeshLayer =
  ## The saved model, uploaded on first use, its triangles shaded by a fixed
  ## light (the level's baked lighting doesn't reach objects).
  if path in r.models: return r.models[path]
  let mesh = loadModel(path, base)
  let light = vec3(-0.35, 0.8, 0.5).normalize
  var byTex: OrderedTable[int, seq[LevelVert]]
  for t in mesh.tris:
    var n = (t.p[1] - t.p[0]).cross(t.p[2] - t.p[0])
    if n.length < 1e-12: continue
    let shade = 0.55'f32 + 0.45'f32 * abs(n.normalize.dot(light))
    for k in 0 .. 2:
      var c = t.col[k]
      for j in 0 .. 2: c[j] = uint8(c[j].float32 * shade)
      byTex.mgetOrPut(t.tex, @[]).add LevelVert(pos: t.p[k], uv: t.uv[k], col: c)
  var data: seq[LevelVert]
  var draws: seq[DrawRange]
  r.modelTextures.add mesh.images
  for tex, verts in byTex:
    let (gl, alpha) = if tex >= 0: r.texture(mesh.images[tex]) else: (0.GLuint, false)
    draws.add DrawRange(first: data.len.int32, count: verts.len.int32, tex: gl, alphaTest: alpha)
    data.add verts
  result = newMesh(data, draws)
  r.models[path] = result

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

proc setSky*(r: Renderer, name: string) =
  ## The skybox of sky `name` (level 0's images, sky.nim), rebuilt when the
  ## name changes or its images have just been extracted.
  if name == r.skyName and (name.len == 0 or r.skyMesh.vao != 0): return
  deleteMesh(r.skyMesh)
  r.skyMesh = MeshLayer()
  r.skyName = name
  if name.len == 0 or not fileExists(skyFace(name, SkyFaces[0])): return
  # Cube corners at +-1, UVs as Oni maps them (see sky.nim).
  proc uvOf(face: string, p: Vec3): Vec2 =
    case face
    of "top": vec2((p.x + 1) / 2, (1 - p.z) / 2)
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
  var low: array[3, float32]   # The sides' bottom row: the bottom face's color.
  var lowCount = 0
  for (face, k) in corners:
    var tex: GLuint
    var col = white
    if face == "bottom":
      if lowCount > 0:
        for c in 0 .. 2: col[c] = uint8(low[c] / lowCount.float32)
    else:
      let path = skyFace(name, face)
      tex = r.texture(path)[0]
      if tex == 0: continue
      glBindTexture(GL_TEXTURE_2D, tex)   # No seams between the faces.
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE.GLint)
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE.GLint)
      if face != "top":
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
  r.geometryVersion = -1

proc drawMesh(r: Renderer, m: MeshLayer, mvp: M4, tint: Vec4, textured: bool, lit = true,
              grid = false) =
  ## grid: TrenchBroom's 3D grid on the faces (r.grid3D; level geometry only).
  if m.vao == 0: return
  glUseProgram(r.levelProg)
  var mm = mvp
  glUniformMatrix4fv(r.uLevelMvp, 1, GL_FALSE, mm[0].addr)
  glUniform1i(r.uLevelTex, 0)
  glUniform1f(r.uLevelLight, (if r.fullbright or not lit: 1'f32 else: 0'f32))
  glUniform4f(r.uLevelTint, tint.x, tint.y, tint.z, tint.w)
  let showGrid = grid and r.grid3D > 0
  glUniform1i(r.uLevelGrid, (if showGrid: 1 else: 0))
  glUniform1f(r.uLevelGridSize, r.grid3D)
  glActiveTexture(GL_TEXTURE0)
  glBindVertexArray(m.vao)
  for d in m.draws:
    let useTex = textured and d.tex != 0
    if showGrid:
      let c = if d.gridDark: 0'f32 else: 1'f32
      glUniform3f(r.uLevelGridColor, c, c, c)
    glUniform1i(r.uLevelUseTex, (if useTex: 1 else: 0))
    glUniform1i(r.uLevelAlphaTest, (if useTex and d.alphaTest: 1 else: 0))
    if useTex: glBindTexture(GL_TEXTURE_2D, d.tex)
    glDrawArrays(GL_TRIANGLES, d.first, d.count)
  glBindVertexArray(0)

proc drawLayer(r: Renderer, layer: Layer, mvp: M4, tint: Vec4, textured: bool, lit = true,
               grid = false) =
  r.drawMesh(r.layers[layer], mvp, tint, textured, lit, grid)

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
  let (grid, bright) = (r.grid3D, r.fullbright)
  r.grid3D = 0
  r.fullbright = false
  r.drawMesh(r.skyMesh, mul(cam.matrix(w.float32, h.float32), m), vec4(1, 1, 1, 1), true)
  (r.grid3D, r.fullbright) = (grid, bright)
  glEnable(GL_BLEND)
  glDepthMask(GL_TRUE)

proc drawModels(r: Renderer, mvp: M4, is3D, textured: bool) =
  for inst in r.modelInstances:
    let m = r.model(inst.path, inst.base)
    let full = mul(mvp, inst.transform)
    if is3D:
      r.drawMesh(m, full, inst.tint, textured)
    else:
      glPolygonMode(GL_FRONT_AND_BACK, GL_LINE)
      let c = inst.wire
      r.drawMesh(m, full, vec4(c[0].float32 / 255, c[1].float32 / 255, c[2].float32 / 255,
                               c[3].float32 / 255), false, lit = false)
      glPolygonMode(GL_FRONT_AND_BACK, GL_FILL)

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

  if not is3D and r.gridLines.len > 0:
    glDisable(GL_DEPTH_TEST)
    r.drawFlat(r.gridLines, GL_LINES, mvp)
  if is3D and opts.sky and opts.textured and not opts.wireframe:
    r.drawSky(cam, w, h)
  glEnable(GL_DEPTH_TEST)
  glDepthFunc(GL_LEQUAL)
  glDepthMask(GL_TRUE)

  if is3D and not opts.wireframe:
    glDisable(GL_BLEND)
    glEnable(GL_POLYGON_OFFSET_FILL)
    glPolygonOffset(1, 1)
    r.drawLayer(lGeometry, mvp, vec4(1, 1, 1, 1), opts.textured, grid = true)
    glDisable(GL_POLYGON_OFFSET_FILL)
    glEnable(GL_BLEND)
  else:
    glPolygonMode(GL_FRONT_AND_BACK, GL_LINE)
    if not is3D: glDisable(GL_DEPTH_TEST)
    r.drawLayer(lGeometry, mvp, (if is3D: vec4(0.75, 0.8, 0.9, 1) else: vec4(0.5, 0.53, 0.6, 1)), false, lit = false)
    glPolygonMode(GL_FRONT_AND_BACK, GL_FILL)
    glEnable(GL_DEPTH_TEST)

  if opts.models and r.modelInstances.len > 0:
    if is3D and not opts.wireframe:
      glDisable(GL_BLEND)
      r.drawModels(mvp, true, opts.textured)
      glEnable(GL_BLEND)
    else:
      if not is3D: glDisable(GL_DEPTH_TEST)
      r.drawModels(mvp, false, false)
      glEnable(GL_DEPTH_TEST)

  glDepthMask(GL_FALSE)
  if opts.markers:
    if is3D:
      r.drawLayer(lInvisible, mvp, vec4(1.0, 0.55, 0.15, 0.30), false, lit = false, grid = true)
    else:
      glPolygonMode(GL_FRONT_AND_BACK, GL_LINE)
      r.drawLayer(lInvisible, mvp, vec4(1.0, 0.55, 0.15, 0.6), false, lit = false)
      glPolygonMode(GL_FRONT_AND_BACK, GL_FILL)
  if opts.rooms:
    r.drawLayer(lRooms, mvp, vec4(0.3, 0.8, 1.0, 0.16), false, lit = false)
  if not is3D: glDisable(GL_DEPTH_TEST)
  r.drawFlat(r.tris, GL_TRIANGLES, mvp)
  glDepthMask(GL_TRUE)
  r.drawFlat(r.lines, GL_LINES, mvp)
  glDisable(GL_DEPTH_TEST)
  r.drawFlat(r.overlayLines, GL_LINES, mvp)

  r.drawCompass(cam, x + 6, glY + 6)
  glDisable(GL_SCISSOR_TEST)
  glDisable(GL_DEPTH_TEST)
  glUseProgram(0)

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

proc faceFill*(buf: var seq[FlatVert], g: Geometry, f: Face, col: array[4, uint8]) =
  for k in 1 ..< f.verts.len - 1:
    for c in [0, k, k + 1]:
      buf.add FlatVert(pos: g.points[f.verts[c]], col: col)

proc faceOutline*(buf: var seq[FlatVert], g: Geometry, f: Face, col: array[4, uint8]) =
  for k in 0 ..< f.verts.len:
    buf.line(g.points[f.verts[k]], g.points[f.verts[(k + 1) mod f.verts.len]], col)
