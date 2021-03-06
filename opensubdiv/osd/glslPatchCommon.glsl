//
//   Copyright 2013 Pixar
//
//   Licensed under the Apache License, Version 2.0 (the "Apache License")
//   with the following modification; you may not use this file except in
//   compliance with the Apache License and the following modification to it:
//   Section 6. Trademarks. is deleted and replaced with:
//
//   6. Trademarks. This License does not grant permission to use the trade
//      names, trademarks, service marks, or product names of the Licensor
//      and its affiliates, except as required to comply with Section 4(c) of
//      the License and to reproduce the content of the NOTICE file.
//
//   You may obtain a copy of the Apache License at
//
//       http://www.apache.org/licenses/LICENSE-2.0
//
//   Unless required by applicable law or agreed to in writing, software
//   distributed under the Apache License with the above modification is
//   distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
//   KIND, either express or implied. See the Apache License for the specific
//   language governing permissions and limitations under the Apache License.
//

//
// typical shader composition ordering (see glDrawRegistry:_CompileShader)
//
//
// - glsl version string  (#version 430)
//
// - common defines       (#define OSD_ENABLE_PATCH_CULL, ...)
// - source defines       (#define VERTEX_SHADER, ...)
//
// - osd headers          (glslPatchCommon: varying structs,
//                         glslPtexCommon: ptex functions)
// - client header        (Osd*Matrix(), displacement callback, ...)
//
// - osd shader source    (glslPatchBSpline, glslPatchGregory, ...)
//     or
//   client shader source (vertex/geometry/fragment shader)
//

//----------------------------------------------------------
// Patches.Common
//----------------------------------------------------------

// XXXdyu all handling of varying data can be managed by client code
#ifndef OSD_USER_VARYING_DECLARE
#define OSD_USER_VARYING_DECLARE
// type var;
#endif

#ifndef OSD_USER_VARYING_ATTRIBUTE_DECLARE
#define OSD_USER_VARYING_ATTRIBUTE_DECLARE
// layout(location = loc) in type var;
#endif

#ifndef OSD_USER_VARYING_PER_VERTEX
#define OSD_USER_VARYING_PER_VERTEX()
// output.var = var;
#endif

#ifndef OSD_USER_VARYING_PER_CONTROL_POINT
#define OSD_USER_VARYING_PER_CONTROL_POINT(ID_OUT, ID_IN)
// output[ID_OUT].var = input[ID_IN].var
#endif

#ifndef OSD_USER_VARYING_PER_EVAL_POINT
#define OSD_USER_VARYING_PER_EVAL_POINT(UV, a, b, c, d)
// output.var =
//     mix(mix(input[a].var, input[b].var, UV.x),
//         mix(input[c].var, input[d].var, UV.x), UV.y)
#endif

// XXXdyu-patch-drawing support for fractional spacing
#undef OSD_FRACTIONAL_ODD_SPACING
#undef OSD_FRACTIONAL_EVEN_SPACING

#if defined OSD_FRACTIONAL_ODD_SPACING
  #define OSD_SPACING fractional_odd_spacing
#elif defined OSD_FRACTIONAL_EVEN_SPACING
  #define OSD_SPACING fractional_even_spacing
#else
  #define OSD_SPACING equal_spacing
#endif

#define M_PI 3.14159265359f

#if __VERSION__ < 420
    #define centroid
#endif

struct ControlVertex {
    vec4 position;
#ifdef OSD_ENABLE_PATCH_CULL
    ivec3 clipFlag;
#endif
};

// XXXdyu all downstream data can be handled by client code
struct OutputVertex {
    vec4 position;
    vec3 normal;
    vec3 tangent;
    vec3 bitangent;
    centroid vec4 patchCoord; // u, v, faceLevel, faceId
    centroid vec2 tessCoord; // tesscoord.st
#if defined OSD_COMPUTE_NORMAL_DERIVATIVES
    vec3 Nu;
    vec3 Nv;
#endif
};

// osd shaders need following functions defined
mat4 OsdModelViewMatrix();
mat4 OsdProjectionMatrix();
mat4 OsdModelViewProjectionMatrix();
float OsdTessLevel();
int OsdGregoryQuadOffsetBase();
int OsdPrimitiveIdBase();
int OsdBaseVertex();

#ifndef OSD_DISPLACEMENT_CALLBACK
#define OSD_DISPLACEMENT_CALLBACK
#endif

// ----------------------------------------------------------------------------
// Patch Parameters
// ----------------------------------------------------------------------------

//
// Each patch has a corresponding patchParam. This is a set of three values
// specifying additional information about the patch:
//
//    faceId    -- topological face identifier (e.g. Ptex FaceId)
//    bitfield  -- refinement-level, non-quad, boundary, transition, uv-offset
//    sharpness -- crease sharpness for single-crease patches
//
// These are stored in OsdPatchParamBuffer indexed by the value returned
// from OsdGetPatchIndex() which is a function of the current PrimitiveID
// along with an optional client provided offset.
//

uniform isamplerBuffer OsdPatchParamBuffer;

int OsdGetPatchIndex(int primitiveId)
{
    return (primitiveId + OsdPrimitiveIdBase());
}

ivec3 OsdGetPatchParam(int patchIndex)
{
    return texelFetch(OsdPatchParamBuffer, patchIndex).xyz;
}

int OsdGetPatchFaceId(ivec3 patchParam)
{
    return (patchParam.x & 0xfffffff);
}

int OsdGetPatchFaceLevel(ivec3 patchParam)
{
    return (1 << ((patchParam.y & 0xf) - ((patchParam.y >> 4) & 1)));
}

int OsdGetPatchRefinementLevel(ivec3 patchParam)
{
    return (patchParam.y & 0xf);
}

int OsdGetPatchBoundaryMask(ivec3 patchParam)
{
    return ((patchParam.y >> 8) & 0xf);
}

int OsdGetPatchTransitionMask(ivec3 patchParam)
{
    return ((patchParam.x >> 28) & 0xf);
}

ivec2 OsdGetPatchFaceUV(ivec3 patchParam)
{
    int u = (patchParam.y >> 22) & 0x3ff;
    int v = (patchParam.y >> 12) & 0x3ff;
    return ivec2(u,v);
}

float OsdGetPatchSharpness(ivec3 patchParam)
{
    return intBitsToFloat(patchParam.z);
}

float OsdGetPatchSingleCreaseSegmentParameter(ivec3 patchParam, vec2 uv)
{
    int boundaryMask = OsdGetPatchBoundaryMask(patchParam);
    float s = 0;
    if ((boundaryMask & 1) != 0) {
        s = 1 - uv.y;
    } else if ((boundaryMask & 2) != 0) {
        s = uv.x;
    } else if ((boundaryMask & 4) != 0) {
        s = uv.y;
    } else if ((boundaryMask & 8) != 0) {
        s = 1 - uv.x;
    }
    return s;
}

ivec4 OsdGetPatchCoord(ivec3 patchParam)
{
    int faceId = OsdGetPatchFaceId(patchParam);
    int faceLevel = OsdGetPatchFaceLevel(patchParam);
    ivec2 faceUV = OsdGetPatchFaceUV(patchParam);
    return ivec4(faceUV.x, faceUV.y, faceLevel, faceId);
}

vec4 OsdInterpolatePatchCoord(vec2 localUV, ivec3 patchParam)
{
    ivec4 perPrimPatchCoord = OsdGetPatchCoord(patchParam);
    int faceId = perPrimPatchCoord.w;
    int faceLevel = perPrimPatchCoord.z;
    vec2 faceUV = vec2(perPrimPatchCoord.x, perPrimPatchCoord.y);
    vec2 uv = localUV/faceLevel + faceUV/faceLevel;
    // add 0.5 to integer values for more robust interpolation
    return vec4(uv.x, uv.y, faceLevel+0.5f, faceId+0.5f);
}

// ----------------------------------------------------------------------------
// face varyings
// ----------------------------------------------------------------------------

uniform samplerBuffer OsdFVarDataBuffer;

#ifndef OSD_FVAR_WIDTH
#define OSD_FVAR_WIDTH 0
#endif

// ------ extract from quads (catmark, bilinear) ---------
// XXX: only linear interpolation is supported

#define OSD_COMPUTE_FACE_VARYING_1(result, fvarOffset, tessCoord)       \
    {                                                                   \
        float v[4];                                                     \
        int primOffset = OsdGetPatchIndex(gl_PrimitiveID) * 4;          \
        for (int i = 0; i < 4; ++i) {                                   \
            int index = (primOffset+i)*OSD_FVAR_WIDTH + fvarOffset;     \
            v[i] = texelFetch(OsdFVarDataBuffer, index).s               \
        }                                                               \
        result = mix(mix(v[0], v[1], tessCoord.s),                      \
                     mix(v[3], v[2], tessCoord.s),                      \
                     tessCoord.t);                                      \
    }

#define OSD_COMPUTE_FACE_VARYING_2(result, fvarOffset, tessCoord)       \
    {                                                                   \
        vec2 v[4];                                                      \
        int primOffset = OsdGetPatchIndex(gl_PrimitiveID) * 4;          \
        for (int i = 0; i < 4; ++i) {                                   \
            int index = (primOffset+i)*OSD_FVAR_WIDTH + fvarOffset;     \
            v[i] = vec2(texelFetch(OsdFVarDataBuffer, index).s,         \
                        texelFetch(OsdFVarDataBuffer, index + 1).s);    \
        }                                                               \
        result = mix(mix(v[0], v[1], tessCoord.s),                      \
                     mix(v[3], v[2], tessCoord.s),                      \
                     tessCoord.t);                                      \
    }

#define OSD_COMPUTE_FACE_VARYING_3(result, fvarOffset, tessCoord)       \
    {                                                                   \
        vec3 v[4];                                                      \
        int primOffset = OsdGetPatchIndex(gl_PrimitiveID) * 4;          \
        for (int i = 0; i < 4; ++i) {                                   \
            int index = (primOffset+i)*OSD_FVAR_WIDTH + fvarOffset;     \
            v[i] = vec3(texelFetch(OsdFVarDataBuffer, index).s,         \
                        texelFetch(OsdFVarDataBuffer, index + 1).s,     \
                        texelFetch(OsdFVarDataBuffer, index + 2).s);    \
        }                                                               \
        result = mix(mix(v[0], v[1], tessCoord.s),                      \
                     mix(v[3], v[2], tessCoord.s),                      \
                     tessCoord.t);                                      \
    }

#define OSD_COMPUTE_FACE_VARYING_4(result, fvarOffset, tessCoord)       \
    {                                                                   \
        vec4 v[4];                                                      \
        int primOffset = OsdGetPatchIndex(gl_PrimitiveID) * 4;          \
        for (int i = 0; i < 4; ++i) {                                   \
            int index = (primOffset+i)*OSD_FVAR_WIDTH + fvarOffset;     \
            v[i] = vec4(texelFetch(OsdFVarDataBuffer, index).s,         \
                        texelFetch(OsdFVarDataBuffer, index + 1).s,     \
                        texelFetch(OsdFVarDataBuffer, index + 2).s,     \
                        texelFetch(OsdFVarDataBuffer, index + 3).s);    \
        }                                                               \
        result = mix(mix(v[0], v[1], tessCoord.s),                      \
                     mix(v[3], v[2], tessCoord.s),                      \
                     tessCoord.t);                                      \
    }

// ------ extract from triangles (loop) ---------
// XXX: no interpolation supproted

#define OSD_COMPUTE_FACE_VARYING_TRI_1(result, fvarOffset, triVert)     \
    {                                                                   \
        int primOffset = OsdGetPatchIndex(gl_PrimitiveID) * 3;          \
        int index = (primOffset+triVert)*OSD_FVAR_WIDTH + fvarOffset;   \
        result = texelFetch(OsdFVarDataBuffer, index).s;                \
    }

#define OSD_COMPUTE_FACE_VARYING_TRI_2(result, fvarOffset, triVert)     \
    {                                                                   \
        int primOffset = OsdGetPatchIndex(gl_PrimitiveID) * 3;          \
        int index = (primOffset+triVert)*OSD_FVAR_WIDTH + fvarOffset;   \
        result = vec2(texelFetch(OsdFVarDataBuffer, index).s,           \
                      texelFetch(OsdFVarDataBuffer, index + 1).s);      \
    }

#define OSD_COMPUTE_FACE_VARYING_TRI_3(result, fvarOffset, triVert)     \
    {                                                                   \
        int primOffset = OsdGetPatchIndex(gl_PrimitiveID) * 3;          \
        int index = (primOffset+triVert)*OSD_FVAR_WIDTH + fvarOffset;   \
        result = vec3(texelFetch(OsdFVarDataBuffer, index).s,           \
                      texelFetch(OsdFVarDataBuffer, index + 1).s,       \
                      texelFetch(OsdFVarDataBuffer, index + 2).s);      \
    }

#define OSD_COMPUTE_FACE_VARYING_TRI_4(result, fvarOffset, triVert)     \
    {                                                                   \
        int primOffset = OsdGetPatchIndex(gl_PrimitiveID) * 3;          \
        int index = (primOffset+triVert)*OSD_FVAR_WIDTH + fvarOffset;   \
        result = vec4(texelFetch(OsdFVarDataBuffer, index).s,           \
                      texelFetch(OsdFVarDataBuffer, index + 1).s,       \
                      texelFetch(OsdFVarDataBuffer, index + 2).s,       \
                      texelFetch(OsdFVarDataBuffer, index + 3).s);      \
    }

// ----------------------------------------------------------------------------
// patch culling
// ----------------------------------------------------------------------------

#ifdef OSD_ENABLE_PATCH_CULL

#define OSD_PATCH_CULL_COMPUTE_CLIPFLAGS(P)                     \
    vec4 clipPos = OsdModelViewProjectionMatrix() * P;          \
    bvec3 clip0 = lessThan(clipPos.xyz, vec3(clipPos.w));       \
    bvec3 clip1 = greaterThan(clipPos.xyz, -vec3(clipPos.w));   \
    outpt.v.clipFlag = ivec3(clip0) + 2*ivec3(clip1);           \

#define OSD_PATCH_CULL(N)                            \
    ivec3 clipFlag = ivec3(0);                       \
    for(int i = 0; i < N; ++i) {                     \
        clipFlag |= inpt[i].v.clipFlag;              \
    }                                                \
    if (clipFlag != ivec3(3) ) {                     \
        gl_TessLevelInner[0] = 0;                    \
        gl_TessLevelInner[1] = 0;                    \
        gl_TessLevelOuter[0] = 0;                    \
        gl_TessLevelOuter[1] = 0;                    \
        gl_TessLevelOuter[2] = 0;                    \
        gl_TessLevelOuter[3] = 0;                    \
        return;                                      \
    }

#else
#define OSD_PATCH_CULL_COMPUTE_CLIPFLAGS(P)
#define OSD_PATCH_CULL(N)
#endif

// ----------------------------------------------------------------------------

void
OsdUnivar4x4(in float u, out float B[4], out float D[4])
{
    float t = u;
    float s = 1.0f - u;

    float A0 = s * s;
    float A1 = 2 * s * t;
    float A2 = t * t;

    B[0] = s * A0;
    B[1] = t * A0 + s * A1;
    B[2] = t * A1 + s * A2;
    B[3] = t * A2;

    D[0] =    - A0;
    D[1] = A0 - A1;
    D[2] = A1 - A2;
    D[3] = A2;
}

void
OsdUnivar4x4(in float u, out float B[4], out float D[4], out float C[4])
{
    float t = u;
    float s = 1.0f - u;

    float A0 = s * s;
    float A1 = 2 * s * t;
    float A2 = t * t;

    B[0] = s * A0;
    B[1] = t * A0 + s * A1;
    B[2] = t * A1 + s * A2;
    B[3] = t * A2;

    D[0] =    - A0;
    D[1] = A0 - A1;
    D[2] = A1 - A2;
    D[3] = A2;

    A0 =   - s;
    A1 = s - t;
    A2 = t;

    C[0] =    - A0;
    C[1] = A0 - A1;
    C[2] = A1 - A2;
    C[3] = A2;
}

// ----------------------------------------------------------------------------

struct OsdPerPatchVertexBezier {
    ivec3 patchParam;
    vec3 P;
#if defined OSD_PATCH_ENABLE_SINGLE_CREASE
    vec3 P1;
    vec3 P2;
    vec2 vSegments;
#endif
};

vec3
OsdEvalBezier(vec3 cp[16], vec2 uv)
{
    vec3 BUCP[4] = vec3[4](vec3(0), vec3(0), vec3(0), vec3(0));

    float B[4], D[4];

    OsdUnivar4x4(uv.x, B, D);
    for (int i=0; i<4; ++i) {
        for (int j=0; j<4; ++j) {
            vec3 A = cp[4*i + j];
            BUCP[i] += A * B[j];
        }
    }

    vec3 P = vec3(0);

    OsdUnivar4x4(uv.y, B, D);
    for (int k=0; k<4; ++k) {
        P += B[k] * BUCP[k];
    }

    return P;
}

// When OSD_PATCH_ENABLE_SINGLE_CREASE is defined,
// this function evaluates single-crease patch, which is segmented into
// 3 parts in the v-direction.
//
//  v=0             vSegment.x        vSegment.y              v=1
//   +------------------+-------------------+------------------+
//   |       cp 0       |     cp 1          |      cp 2        |
//   | (infinite sharp) | (floor sharpness) | (ceil sharpness) |
//   +------------------+-------------------+------------------+
//
vec3
OsdEvalBezier(OsdPerPatchVertexBezier cp[16], ivec3 patchParam, vec2 uv)
{
    vec3 BUCP[4] = vec3[4](vec3(0), vec3(0), vec3(0), vec3(0));

    float B[4], D[4];
    float s = OsdGetPatchSingleCreaseSegmentParameter(patchParam, uv);

    OsdUnivar4x4(uv.x, B, D);
#if defined OSD_PATCH_ENABLE_SINGLE_CREASE
    vec2 vSegments = cp[0].vSegments;
    if (s <= vSegments.x) {
        for (int i=0; i<4; ++i) {
            for (int j=0; j<4; ++j) {
                vec3 A = cp[4*i + j].P;
                BUCP[i] += A * B[j];
            }
        }
    } else if (s <= vSegments.y) {
        for (int i=0; i<4; ++i) {
            for (int j=0; j<4; ++j) {
                vec3 A = cp[4*i + j].P1;
                BUCP[i] += A * B[j];
            }
        }
    } else {
        for (int i=0; i<4; ++i) {
            for (int j=0; j<4; ++j) {
                vec3 A = cp[4*i + j].P2;
                BUCP[i] += A * B[j];
            }
        }
    }
#else
    for (int i=0; i<4; ++i) {
        for (int j=0; j<4; ++j) {
            vec3 A = cp[4*i + j].P;
            BUCP[i] += A * B[j];
        }
    }
#endif

    vec3 P = vec3(0);

    OsdUnivar4x4(uv.y, B, D);
    for (int k=0; k<4; ++k) {
        P += B[k] * BUCP[k];
    }

    return P;
}

// ----------------------------------------------------------------------------
// Boundary Interpolation
// ----------------------------------------------------------------------------

void
OsdComputeBSplineBoundaryPoints(inout vec3 cpt[16], ivec3 patchParam)
{
    int boundaryMask = OsdGetPatchBoundaryMask(patchParam);

    if ((boundaryMask & 1) != 0) {
        cpt[0] = 2*cpt[4] - cpt[8];
        cpt[1] = 2*cpt[5] - cpt[9];
        cpt[2] = 2*cpt[6] - cpt[10];
        cpt[3] = 2*cpt[7] - cpt[11];
    }
    if ((boundaryMask & 2) != 0) {
        cpt[3] = 2*cpt[2] - cpt[1];
        cpt[7] = 2*cpt[6] - cpt[5];
        cpt[11] = 2*cpt[10] - cpt[9];
        cpt[15] = 2*cpt[14] - cpt[13];
    }
    if ((boundaryMask & 4) != 0) {
        cpt[12] = 2*cpt[8] - cpt[4];
        cpt[13] = 2*cpt[9] - cpt[5];
        cpt[14] = 2*cpt[10] - cpt[6];
        cpt[15] = 2*cpt[11] - cpt[7];
    }
    if ((boundaryMask & 8) != 0) {
        cpt[0] = 2*cpt[1] - cpt[2];
        cpt[4] = 2*cpt[5] - cpt[6];
        cpt[8] = 2*cpt[9] - cpt[10];
        cpt[12] = 2*cpt[13] - cpt[14];
    }
}

// ----------------------------------------------------------------------------
// Tessellation
// ----------------------------------------------------------------------------

//
// Organization of B-spline and Bezier control points.
//
// Each patch is defined by 16 control points (labeled 0-15).
//
// The patch will be evaluated across the domain from (0,0) at
// the lower-left to (1,1) at the upper-right. When computing
// adaptive tessellation metrics, we consider refined vertex-vertex
// and edge-vertex points along the transition edges of the patch
// (labeled vv* and ev* respectively).
//
// The two segments of each transition edge are labeled Lo and Hi,
// with the Lo segment occuring before the Hi segment along the
// transition edge's domain parameterization. These Lo and Hi segment
// tessellation levels determine how domain evaluation coordinates
// are remapped along transition edges. The Hi segment value will
// be zero for a non-transition edge.
//
// (0,1)                                         (1,1)
//
//   vv3                  ev23                   vv2
//        |       Lo3       |       Hi3       |
//      --O-----------O-----+-----O-----------O--
//        | 12        | 13     14 |        15 |
//        |           |           |           |
//        |           |           |           |
//    Hi0 |           |           |           | Hi2
//        |           |           |           |
//        O-----------O-----------O-----------O
//        | 8         | 9      10 |        11 |
//        |           |           |           |
// ev03 --+           |           |           +-- ev12
//        |           |           |           |
//        | 4         | 5       6 |         7 |
//        O-----------O-----------O-----------O
//        |           |           |           |
//    Lo0 |           |           |           | Lo2
//        |           |           |           |
//        |           |           |           |
//        | 0         | 1       2 |         3 |
//      --O-----------O-----+-----O-----------O--
//        |       Lo1       |       Hi1       |
//   vv0                  ev01                   vv1
//
// (0,0)                                         (1,0)
//

#define OSD_MAX_TESS_LEVEL gl_MaxTessGenLevel

float OsdComputePostProjectionSphereExtent(vec3 center, float diameter)
{
    vec4 p = OsdProjectionMatrix() * vec4(center, 1.0);
    return abs(diameter * OsdProjectionMatrix()[1][1] / p.w);
}

float OsdComputeTessLevel(vec3 p0, vec3 p1)
{
    // Adaptive factor can be any computation that depends only on arg values.
    // Project the diameter of the edge's bounding sphere instead of using the
    // length of the projected edge itself to avoid problems near silhouettes.
    p0 = (OsdModelViewMatrix() * vec4(p0, 1.0)).xyz;
    p1 = (OsdModelViewMatrix() * vec4(p1, 1.0)).xyz;
    vec3 center = (p0 + p1) / 2.0;
    float diameter = distance(p0, p1);
    float projLength = OsdComputePostProjectionSphereExtent(center, diameter);
    float tessLevel = round(max(1.0, OsdTessLevel() * projLength));

    // We restrict adaptive tessellation levels to half of the device
    // supported maximum because transition edges are split into two
    // halfs and the sum of the two corresponding levels must not exceed
    // the device maximum. We impose this limit even for non-transition
    // edges because a non-transition edge must be able to match up with
    // one half of the transition edge of an adjacent transition patch.
    return min(tessLevel, OSD_MAX_TESS_LEVEL / 2);
}

void
OsdGetTessLevelsUniform(ivec3 patchParam,
                        out vec4 tessOuterLo, out vec4 tessOuterHi)
{
    // Uniform factors are simple powers of two for each level.
    // The maximum here can be increased if we know the maximum
    // refinement level of the mesh:
    //     min(OSD_MAX_TESS_LEVEL, pow(2, MaximumRefinementLevel-1)
    int refinementLevel = OsdGetPatchRefinementLevel(patchParam);
    float tessLevel = min(OsdTessLevel(), OSD_MAX_TESS_LEVEL) /
                        pow(2, refinementLevel-1);

    // tessLevels of transition edge should be clamped to 2.
    int transitionMask = OsdGetPatchTransitionMask(patchParam);
    vec4 tessLevelMin = vec4(1) + vec4(((transitionMask & 8) >> 3),
                                       ((transitionMask & 1) >> 0),
                                       ((transitionMask & 2) >> 1),
                                       ((transitionMask & 4) >> 2));

    tessOuterLo = max(vec4(tessLevel), tessLevelMin);
    tessOuterHi = vec4(0);
}

void
OsdGetTessLevelsRefinedPoints(vec3 cp[16], ivec3 patchParam,
                              out vec4 tessOuterLo, out vec4 tessOuterHi)
{
    // Each edge of a transition patch is adjacent to one or two patches
    // at the next refined level of subdivision. We compute the corresponding
    // vertex-vertex and edge-vertex refined points along the edges of the
    // patch using Catmull-Clark subdivision stencil weights.
    // For simplicity, we let the optimizer discard unused computation.

    vec3 vv0 = (cp[0] + cp[2] + cp[8] + cp[10]) * 0.015625 +
               (cp[1] + cp[4] + cp[6] + cp[9]) * 0.09375 + cp[5] * 0.5625;
    vec3 ev01 = (cp[1] + cp[2] + cp[9] + cp[10]) * 0.0625 +
                (cp[5] + cp[6]) * 0.375;

    vec3 vv1 = (cp[1] + cp[3] + cp[9] + cp[11]) * 0.015625 +
               (cp[2] + cp[5] + cp[7] + cp[10]) * 0.09375 + cp[6] * 0.5625;
    vec3 ev12 = (cp[5] + cp[7] + cp[9] + cp[11]) * 0.0625 +
                (cp[6] + cp[10]) * 0.375;

    vec3 vv2 = (cp[5] + cp[7] + cp[13] + cp[15]) * 0.015625 +
               (cp[6] + cp[9] + cp[11] + cp[14]) * 0.09375 + cp[10] * 0.5625;
    vec3 ev23 = (cp[5] + cp[6] + cp[13] + cp[14]) * 0.0625 +
                (cp[9] + cp[10]) * 0.375;

    vec3 vv3 = (cp[4] + cp[6] + cp[12] + cp[14]) * 0.015625 +
               (cp[5] + cp[8] + cp[10] + cp[13]) * 0.09375 + cp[9] * 0.5625;
    vec3 ev03 = (cp[4] + cp[6] + cp[8] + cp[10]) * 0.0625 +
                (cp[5] + cp[9]) * 0.375;

    tessOuterLo = vec4(0);
    tessOuterHi = vec4(0);

    int transitionMask = OsdGetPatchTransitionMask(patchParam);

    if ((transitionMask & 8) != 0) {
        tessOuterLo[0] = OsdComputeTessLevel(vv0, ev03);
        tessOuterHi[0] = OsdComputeTessLevel(vv3, ev03);
    } else {
        tessOuterLo[0] = OsdComputeTessLevel(cp[5], cp[9]);
    }
    if ((transitionMask & 1) != 0) {
        tessOuterLo[1] = OsdComputeTessLevel(vv0, ev01);
        tessOuterHi[1] = OsdComputeTessLevel(vv1, ev01);
    } else {
        tessOuterLo[1] = OsdComputeTessLevel(cp[5], cp[6]);
    }
    if ((transitionMask & 2) != 0) {
        tessOuterLo[2] = OsdComputeTessLevel(vv1, ev12);
        tessOuterHi[2] = OsdComputeTessLevel(vv2, ev12);
    } else {
        tessOuterLo[2] = OsdComputeTessLevel(cp[6], cp[10]);
    }
    if ((transitionMask & 4) != 0) {
        tessOuterLo[3] = OsdComputeTessLevel(vv3, ev23);
        tessOuterHi[3] = OsdComputeTessLevel(vv2, ev23);
    } else {
        tessOuterLo[3] = OsdComputeTessLevel(cp[9], cp[10]);
    }
}

void
OsdGetTessLevelsLimitPoints(OsdPerPatchVertexBezier cpBezier[16],
                 ivec3 patchParam, out vec4 tessOuterLo, out vec4 tessOuterHi)
{
    // Each edge of a transition patch is adjacent to one or two patches
    // at the next refined level of subdivision. When the patch control
    // points have been converted to the Bezier basis, the control points
    // at the four corners are on the limit surface (since a Bezier patch
    // interpolates its corner control points). We can compute an adaptive
    // tessellation level for transition edges on the limit surface by
    // evaluating a limit position at the mid point of each transition edge.

    tessOuterLo = vec4(0);
    tessOuterHi = vec4(0);

    int transitionMask = OsdGetPatchTransitionMask(patchParam);

#if defined OSD_PATCH_ENABLE_SINGLE_CREASE
    // PERFOMANCE: we just need to pick the correct corner points from P, P1, P2
    vec3 p0 = OsdEvalBezier(cpBezier, patchParam, vec2(0.0, 0.0));
    vec3 p3 = OsdEvalBezier(cpBezier, patchParam, vec2(1.0, 0.0));
    vec3 p12 = OsdEvalBezier(cpBezier, patchParam, vec2(0.0, 1.0));
    vec3 p15 = OsdEvalBezier(cpBezier, patchParam, vec2(1.0, 1.0));
    if ((transitionMask & 8) != 0) {
        vec3 ev03 = OsdEvalBezier(cpBezier, patchParam, vec2(0.0, 0.5));
        tessOuterLo[0] = OsdComputeTessLevel(p0, ev03);
        tessOuterHi[0] = OsdComputeTessLevel(p12, ev03);
    } else {
        tessOuterLo[0] = OsdComputeTessLevel(p0, p12);
    }
    if ((transitionMask & 1) != 0) {
        vec3 ev01 = OsdEvalBezier(cpBezier, patchParam, vec2(0.5, 0.0));
        tessOuterLo[1] = OsdComputeTessLevel(p0, ev01);
        tessOuterHi[1] = OsdComputeTessLevel(p3, ev01);
    } else {
        tessOuterLo[1] = OsdComputeTessLevel(p0, p3);
    }
    if ((transitionMask & 2) != 0) {
        vec3 ev12 = OsdEvalBezier(cpBezier, patchParam, vec2(1.0, 0.5));
        tessOuterLo[2] = OsdComputeTessLevel(p3, ev12);
        tessOuterHi[2] = OsdComputeTessLevel(p15, ev12);
    } else {
        tessOuterLo[2] = OsdComputeTessLevel(p3, p15);
    }
    if ((transitionMask & 4) != 0) {
        vec3 ev23 = OsdEvalBezier(cpBezier, patchParam, vec2(0.5, 1.0));
        tessOuterLo[3] = OsdComputeTessLevel(p12, ev23);
        tessOuterHi[3] = OsdComputeTessLevel(p15, ev23);
    } else {
        tessOuterLo[3] = OsdComputeTessLevel(p12, p15);
    }
#else
    if ((transitionMask & 8) != 0) {
        vec3 ev03 = OsdEvalBezier(cpBezier, patchParam, vec2(0.0, 0.5));
        tessOuterLo[0] = OsdComputeTessLevel(cpBezier[0].P, ev03);
        tessOuterHi[0] = OsdComputeTessLevel(cpBezier[12].P, ev03);
    } else {
        tessOuterLo[0] = OsdComputeTessLevel(cpBezier[0].P, cpBezier[12].P);
    }
    if ((transitionMask & 1) != 0) {
        vec3 ev01 = OsdEvalBezier(cpBezier, patchParam, vec2(0.5, 0.0));
        tessOuterLo[1] = OsdComputeTessLevel(cpBezier[0].P, ev01);
        tessOuterHi[1] = OsdComputeTessLevel(cpBezier[3].P, ev01);
    } else {
        tessOuterLo[1] = OsdComputeTessLevel(cpBezier[0].P, cpBezier[3].P);
    }
    if ((transitionMask & 2) != 0) {
        vec3 ev12 = OsdEvalBezier(cpBezier, patchParam, vec2(1.0, 0.5));
        tessOuterLo[2] = OsdComputeTessLevel(cpBezier[3].P, ev12);
        tessOuterHi[2] = OsdComputeTessLevel(cpBezier[15].P, ev12);
    } else {
        tessOuterLo[2] = OsdComputeTessLevel(cpBezier[3].P, cpBezier[15].P);
    }
    if ((transitionMask & 4) != 0) {
        vec3 ev23 = OsdEvalBezier(cpBezier, patchParam, vec2(0.5, 1.0));
        tessOuterLo[3] = OsdComputeTessLevel(cpBezier[12].P, ev23);
        tessOuterHi[3] = OsdComputeTessLevel(cpBezier[15].P, ev23);
    } else {
        tessOuterLo[3] = OsdComputeTessLevel(cpBezier[12].P, cpBezier[15].P);
    }
#endif
}

void
OsdGetTessLevelsUniform(ivec3 patchParam,
                 out vec4 tessLevelOuter, out vec2 tessLevelInner,
                 out vec4 tessOuterLo, out vec4 tessOuterHi)
{
    // uniform tessellation
    OsdGetTessLevelsUniform(patchParam, tessOuterLo, tessOuterHi);

    // Outer levels are the sum of the Lo and Hi segments where the Hi
    // segments will have a length of zero for non-transition edges.
    tessLevelOuter = tessOuterLo + tessOuterHi;

    // Inner levels are the average the corresponding outer levels.
    tessLevelInner[0] = (tessLevelOuter[1] + tessLevelOuter[3]) * 0.5;
    tessLevelInner[1] = (tessLevelOuter[0] + tessLevelOuter[2]) * 0.5;
}

void
OsdGetTessLevelsAdaptiveRefinedPoints(vec3 cpRefined[16], ivec3 patchParam,
                        out vec4 tessLevelOuter, out vec2 tessLevelInner,
                        out vec4 tessOuterLo, out vec4 tessOuterHi)
{
    OsdGetTessLevelsRefinedPoints(cpRefined, patchParam, tessOuterLo, tessOuterHi);

    // Outer levels are the sum of the Lo and Hi segments where the Hi
    // segments will have a length of zero for non-transition edges.
    tessLevelOuter = tessOuterLo + tessOuterHi;

    // Inner levels are the average the corresponding outer levels.
    tessLevelInner[0] = (tessLevelOuter[1] + tessLevelOuter[3]) * 0.5;
    tessLevelInner[1] = (tessLevelOuter[0] + tessLevelOuter[2]) * 0.5;
}

void
OsdGetTessLevelsAdaptiveLimitPoints(OsdPerPatchVertexBezier cpBezier[16],
                 ivec3 patchParam,
                 out vec4 tessLevelOuter, out vec2 tessLevelInner,
                 out vec4 tessOuterLo, out vec4 tessOuterHi)
{
    OsdGetTessLevelsLimitPoints(cpBezier, patchParam, tessOuterLo, tessOuterHi);

    // Outer levels are the sum of the Lo and Hi segments where the Hi
    // segments will have a length of zero for non-transition edges.
    tessLevelOuter = tessOuterLo + tessOuterHi;

    // Inner levels are the average the corresponding outer levels.
    tessLevelInner[0] = (tessLevelOuter[1] + tessLevelOuter[3]) * 0.5;
    tessLevelInner[1] = (tessLevelOuter[0] + tessLevelOuter[2]) * 0.5;
}

void
OsdGetTessLevels(vec3 cp0, vec3 cp1, vec3 cp2, vec3 cp3,
                 ivec3 patchParam,
                 out vec4 tessLevelOuter, out vec2 tessLevelInner)
{
    vec4 tessOuterLo = vec4(0);
    vec4 tessOuterHi = vec4(0);

#if defined OSD_ENABLE_SCREENSPACE_TESSELLATION
    tessOuterLo[0] = OsdComputeTessLevel(cp0, cp1);
    tessOuterLo[1] = OsdComputeTessLevel(cp0, cp3);
    tessOuterLo[2] = OsdComputeTessLevel(cp2, cp3);
    tessOuterLo[3] = OsdComputeTessLevel(cp1, cp2);
    tessOuterHi = vec4(0);
#else
    OsdGetTessLevelsUniform(patchParam, tessOuterLo, tessOuterHi);
#endif

    // Outer levels are the sum of the Lo and Hi segments where the Hi
    // segments will have a length of zero for non-transition edges.
    tessLevelOuter = tessOuterLo + tessOuterHi;

    // Inner levels are the average the corresponding outer levels.
    tessLevelInner[0] = (tessLevelOuter[1] + tessLevelOuter[3]) * 0.5;
    tessLevelInner[1] = (tessLevelOuter[0] + tessLevelOuter[2]) * 0.5;
}

float
OsdGetTessTransitionSplit(float t, float n0, float n1)
{
    float ti = round(t * (n0 + n1));

    if (ti <= n0) {
        return 0.5 * (ti / n0);
    } else {
        return 0.5 * ((ti - n0) / n1) + 0.5;
    }
}

vec2
OsdGetTessParameterization(vec2 uv, vec4 tessOuterLo, vec4 tessOuterHi)
{
    vec2 UV = uv;
    if (UV.x == 0 && tessOuterHi[0] > 0) {
        UV.y = OsdGetTessTransitionSplit(UV.y, tessOuterLo[0], tessOuterHi[0]);
    } else
    if (UV.y == 0 && tessOuterHi[1] > 0) {
        UV.x = OsdGetTessTransitionSplit(UV.x, tessOuterLo[1], tessOuterHi[1]);
    } else
    if (UV.x == 1 && tessOuterHi[2] > 0) {
        UV.y = OsdGetTessTransitionSplit(UV.y, tessOuterLo[2], tessOuterHi[2]);
    } else
    if (UV.y == 1 && tessOuterHi[3] > 0) {
        UV.x = OsdGetTessTransitionSplit(UV.x, tessOuterLo[3], tessOuterHi[3]);
    }
    return UV;
}

// ----------------------------------------------------------------------------
// BSpline
// ----------------------------------------------------------------------------

// compute single-crease patch matrix
mat4
OsdComputeMs(float sharpness)
{
    float s = pow(2.0f, sharpness);
    float s2 = s*s;
    float s3 = s2*s;

    mat4 m = mat4(
        0, s + 1 + 3*s2 - s3, 7*s - 2 - 6*s2 + 2*s3, (1-s)*(s-1)*(s-1),
        0,       (1+s)*(1+s),        6*s - 2 - 2*s2,       (s-1)*(s-1),
        0,               1+s,               6*s - 2,               1-s,
        0,                 1,               6*s - 2,                 1);

    m /= (s*6.0);
    m[0][0] = 1.0/6.0;

    return m;
}

// flip matrix orientation
mat4
OsdFlipMatrix(mat4 m)
{
    return mat4(m[3][3], m[3][2], m[3][1], m[3][0],
                m[2][3], m[2][2], m[2][1], m[2][0],
                m[1][3], m[1][2], m[1][1], m[1][0],
                m[0][3], m[0][2], m[0][1], m[0][0]);
}

// convert BSpline cv to Bezier cv
void
OsdComputePerPatchVertexBSpline(ivec3 patchParam, int ID, vec3 cv[16],
                                out OsdPerPatchVertexBezier result)
{
    // Regular BSpline to Bezier
    mat4 Q = mat4(
        1.f/6.f, 4.f/6.f, 1.f/6.f, 0.f,
        0.f,     4.f/6.f, 2.f/6.f, 0.f,
        0.f,     2.f/6.f, 4.f/6.f, 0.f,
        0.f,     1.f/6.f, 4.f/6.f, 1.f/6.f
    );

    result.patchParam = patchParam;

    int i = ID%4;
    int j = ID/4;

#if defined OSD_PATCH_ENABLE_SINGLE_CREASE

    // Infinitely Sharp (boundary)
    mat4 Mi = mat4(
        1.f/6.f, 4.f/6.f, 1.f/6.f, 0.f,
        0.f,     4.f/6.f, 2.f/6.f, 0.f,
        0.f,     2.f/6.f, 4.f/6.f, 0.f,
        0.f,     0.f,     1.f,     0.f
    );

    mat4 Mj, Ms;
    float sharpness = OsdGetPatchSharpness(patchParam);
    if (sharpness > 0) {
        float Sf = floor(sharpness);
        float Sc = ceil(sharpness);
        float Sr = fract(sharpness);
        mat4 Mf = OsdComputeMs(Sf);
        mat4 Mc = OsdComputeMs(Sc);
        Mj = (1-Sr) * Mf + Sr * Mi;
        Ms = (1-Sr) * Mf + Sr * Mc;
        float s0 = 1 - pow(2, -floor(sharpness));
        float s1 = 1 - pow(2, -ceil(sharpness));
        result.vSegments = vec2(s0, s1);
    } else {
        Mj = Ms = Mi;
        result.vSegments = vec2(0);
    }
    result.P  = vec3(0); // 0 to 1-2^(-Sf)
    result.P1 = vec3(0); // 1-2^(-Sf) to 1-2^(-Sc)
    result.P2 = vec3(0); // 1-2^(-Sc) to 1

    mat4 MUi, MUj, MUs;
    mat4 MVi, MVj, MVs;
    MUi = MUj = MUs = Q;
    MVi = MVj = MVs = Q;

    int boundaryMask = OsdGetPatchBoundaryMask(patchParam);
    if ((boundaryMask & 1) != 0) {
        MVi = OsdFlipMatrix(Mi);
        MVj = OsdFlipMatrix(Mj);
        MVs = OsdFlipMatrix(Ms);
    }
    if ((boundaryMask & 2) != 0) {
        MUi = Mi;
        MUj = Mj;
        MUs = Ms;
    }
    if ((boundaryMask & 4) != 0) {
        MVi = Mi;
        MVj = Mj;
        MVs = Ms;
    }
    if ((boundaryMask & 8) != 0) {
        MUi = OsdFlipMatrix(Mi);
        MUj = OsdFlipMatrix(Mj);
        MUs = OsdFlipMatrix(Ms);
    }

    vec3 Hi[4], Hj[4], Hs[4];
    for (int l=0; l<4; ++l) {
        Hi[l] = Hj[l] = Hs[l] = vec3(0);
        for (int k=0; k<4; ++k) {
            Hi[l] += MUi[i][k] * cv[l*4 + k];
            Hj[l] += MUj[i][k] * cv[l*4 + k];
            Hs[l] += MUs[i][k] * cv[l*4 + k];
        }
    }
    for (int k=0; k<4; ++k) {
        result.P  += MVi[j][k]*Hi[k];
        result.P1 += MVj[j][k]*Hj[k];
        result.P2 += MVs[j][k]*Hs[k];
    }
#else
    OsdComputeBSplineBoundaryPoints(cv, patchParam);

    vec3 H[4];
    for (int l=0; l<4; ++l) {
        H[l] = vec3(0);
        for (int k=0; k<4; ++k) {
            H[l] += Q[i][k] * cv[l*4 + k];
        }
    }
    {
        result.P = vec3(0);
        for (int k=0; k<4; ++k) {
            result.P += Q[j][k]*H[k];
        }
    }
#endif
}

void
OsdEvalPatchBezier(ivec3 patchParam, vec2 UV,
                   OsdPerPatchVertexBezier cv[16],
                   out vec3 P, out vec3 dPu, out vec3 dPv,
                   out vec3 N, out vec3 dNu, out vec3 dNv)
{
#ifdef OSD_COMPUTE_NORMAL_DERIVATIVES
    float B[4], D[4], C[4];
    vec3 BUCP[4] = vec3[4](vec3(0), vec3(0), vec3(0), vec3(0)),
         DUCP[4] = vec3[4](vec3(0), vec3(0), vec3(0), vec3(0)),
         CUCP[4] = vec3[4](vec3(0), vec3(0), vec3(0), vec3(0));
    OsdUnivar4x4(UV.x, B, D, C);
#else
    float B[4], D[4];
    vec3 BUCP[4] = vec3[4](vec3(0), vec3(0), vec3(0), vec3(0)),
         DUCP[4] = vec3[4](vec3(0), vec3(0), vec3(0), vec3(0));
    OsdUnivar4x4(UV.x, B, D);
#endif

    // ----------------------------------------------------------------
#if defined OSD_PATCH_ENABLE_SINGLE_CREASE
    vec2 vSegments = cv[0].vSegments;
    float s = OsdGetPatchSingleCreaseSegmentParameter(patchParam, UV);

    for (int i=0; i<4; ++i) {
        for (int j=0; j<4; ++j) {
            int k = 4*i + j;

            vec3 A = (s <= vSegments.x) ? cv[k].P
                :   ((s <= vSegments.y) ? cv[k].P1
                                        : cv[k].P2);

            BUCP[i] += A * B[j];
            DUCP[i] += A * D[j];
#ifdef OSD_COMPUTE_NORMAL_DERIVATIVES
            CUCP[i] += A * C[j];
#endif
        }
    }
#else
    // ----------------------------------------------------------------
    for (int i=0; i<4; ++i) {
        for (int j=0; j<4; ++j) {
            vec3 A = cv[4*i + j].P;
            BUCP[i] += A * B[j];
            DUCP[i] += A * D[j];
#ifdef OSD_COMPUTE_NORMAL_DERIVATIVES
            CUCP[i] += A * C[j];
#endif
        }
    }
#endif
    // ----------------------------------------------------------------

    P   = vec3(0);
    dPu = vec3(0);
    dPv = vec3(0);

#ifdef OSD_COMPUTE_NORMAL_DERIVATIVES
    // used for weingarten term
    OsdUnivar4x4(UV.y, B, D, C);

    vec3 dUU = vec3(0);
    vec3 dVV = vec3(0);
    vec3 dUV = vec3(0);

    for (int k=0; k<4; ++k) {
        P   += B[k] * BUCP[k];
        dPu += B[k] * DUCP[k];
        dPv += D[k] * BUCP[k];

        dUU += B[k] * CUCP[k];
        dVV += C[k] * BUCP[k];
        dUV += D[k] * DUCP[k];
    }

    int level = OsdGetPatchFaceLevel(patchParam);
    dPu *= 3 * level;
    dPv *= 3 * level;
    dUU *= 6 * level;
    dVV *= 6 * level;
    dUV *= 9 * level;

    vec3 n = cross(dPu, dPv);
    N = normalize(n);

    float E = dot(dPu, dPu);
    float F = dot(dPu, dPv);
    float G = dot(dPv, dPv);
    float e = dot(N, dUU);
    float f = dot(N, dUV);
    float g = dot(N, dVV);

    dNu = (f*F-e*G)/(E*G-F*F) * dPu + (e*F-f*E)/(E*G-F*F) * dPv;
    dNv = (g*F-f*G)/(E*G-F*F) * dPu + (f*F-g*E)/(E*G-F*F) * dPv;

    dNu = dNu/length(n) - n * (dot(dNu,n)/pow(dot(n,n), 1.5));
    dNv = dNv/length(n) - n * (dot(dNv,n)/pow(dot(n,n), 1.5));
#else
    OsdUnivar4x4(UV.y, B, D);

    for (int k=0; k<4; ++k) {
        P   += B[k] * BUCP[k];
        dPu += B[k] * DUCP[k];
        dPv += D[k] * BUCP[k];
    }
    int level = OsdGetPatchFaceLevel(patchParam);
    dPu *= 3 * level;
    dPv *= 3 * level;

    N = normalize(cross(dPu, dPv));
    dNu = vec3(0);
    dNv = vec3(0);
#endif
}

// ----------------------------------------------------------------------------
// Gregory Basis
// ----------------------------------------------------------------------------

struct OsdPerPatchVertexGregoryBasis {
    ivec3 patchParam;
    vec3 P;
};

void
OsdComputePerPatchVertexGregoryBasis(ivec3 patchParam, int ID, vec3 cv,
                                     out OsdPerPatchVertexGregoryBasis result)
{
    result.patchParam = patchParam;
    result.P = cv;
}

void
OsdEvalPatchGregory(ivec3 patchParam, vec2 UV, vec3 cv[20],
                    out vec3 P, out vec3 dPu, out vec3 dPv,
                    out vec3 N, out vec3 dNu, out vec3 dNv)
{
    float u = UV.x, v = UV.y;
    float U = 1-u, V = 1-v;

    //(0,1)                              (1,1)
    //   P3         e3-      e2+         E2
    //      15------17-------11-------10
    //      |        |        |        |
    //      |        |        |        |
    //      |        | f3-    | f2+    |
    //      |       19       13        |
    //  e3+ 16-----18          14-----12 e2-
    //      |     f3+          f2-     |
    //      |                          |
    //      |                          |
    //      |     f0-         f1+      |
    //  e0- 2------4            8------6 e1+
    //      |        3 f0+    9        |
    //      |        |        | f1-    |
    //      |        |        |        |
    //      |        |        |        |
    //      0--------1--------7--------5
    //    P0        e0+      e1-         E1
    //(0,0)                               (1,0)

    float d11 = u+v;
    float d12 = U+v;
    float d21 = u+V;
    float d22 = U+V;

    vec3 q[16];

    q[ 5] = (d11 == 0.0) ? cv[3]  : (u*cv[3] + v*cv[4])/d11;
    q[ 6] = (d12 == 0.0) ? cv[8]  : (U*cv[9] + v*cv[8])/d12;
    q[ 9] = (d21 == 0.0) ? cv[18] : (u*cv[19] + V*cv[18])/d21;
    q[10] = (d22 == 0.0) ? cv[13] : (U*cv[13] + V*cv[14])/d22;

    q[ 0] = cv[0];
    q[ 1] = cv[1];
    q[ 2] = cv[7];
    q[ 3] = cv[5];
    q[ 4] = cv[2];
    q[ 7] = cv[6];
    q[ 8] = cv[16];
    q[11] = cv[12];
    q[12] = cv[15];
    q[13] = cv[17];
    q[14] = cv[11];
    q[15] = cv[10];

    P   = vec3(0);
    dPu = vec3(0);
    dPv = vec3(0);

#ifdef OSD_COMPUTE_NORMAL_DERIVATIVES
    float B[4], D[4], C[4];
    vec3 BUCP[4] = vec3[4](vec3(0), vec3(0), vec3(0), vec3(0)),
         DUCP[4] = vec3[4](vec3(0), vec3(0), vec3(0), vec3(0)),
         CUCP[4] = vec3[4](vec3(0), vec3(0), vec3(0), vec3(0));
    vec3 dUU = vec3(0);
    vec3 dVV = vec3(0);
    vec3 dUV = vec3(0);

    OsdUnivar4x4(UV.x, B, D, C);

    for (int i=0; i<4; ++i) {
        for (int j=0; j<4; ++j) {
            vec3 A = q[4*i + j];
            BUCP[i] += A * B[j];
            DUCP[i] += A * D[j];
            CUCP[i] += A * C[j];
        }
    }

    OsdUnivar4x4(UV.y, B, D, C);

    for (int i=0; i<4; ++i) {
        P   += B[i] * BUCP[i];
        dPu += B[i] * DUCP[i];
        dPv += D[i] * BUCP[i];
        dUU += B[i] * CUCP[i];
        dVV += C[i] * BUCP[i];
        dUV += D[i] * DUCP[i];
    }

    int level = OsdGetPatchFaceLevel(patchParam);
    dPu *= 3 * level;
    dPv *= 3 * level;
    dUU *= 6 * level;
    dVV *= 6 * level;
    dUV *= 9 * level;

    vec3 n = cross(dPu, dPv);
    N = normalize(n);

    float E = dot(dPu, dPu);
    float F = dot(dPu, dPv);
    float G = dot(dPv, dPv);
    float e = dot(N, dUU);
    float f = dot(N, dUV);
    float g = dot(N, dVV);

    dNu = (f*F-e*G)/(E*G-F*F) * dPu + (e*F-f*E)/(E*G-F*F) * dPv;
    dNv = (g*F-f*G)/(E*G-F*F) * dPu + (f*F-g*E)/(E*G-F*F) * dPv;

    dNu = dNu/length(n) - n * (dot(dNu,n)/pow(dot(n,n), 1.5));
    dNv = dNv/length(n) - n * (dot(dNv,n)/pow(dot(n,n), 1.5));
#else
    float B[4], D[4];
    vec3 BUCP[4] = vec3[4](vec3(0), vec3(0), vec3(0), vec3(0)),
         DUCP[4] = vec3[4](vec3(0), vec3(0), vec3(0), vec3(0));

    OsdUnivar4x4(UV.x, B, D);

    for (int i=0; i<4; ++i) {
        for (int j=0; j<4; ++j) {
            vec3 A = q[4*i + j];
            BUCP[i] += A * B[j];
            DUCP[i] += A * D[j];
        }
    }

    OsdUnivar4x4(UV.y, B, D);

    for (int i=0; i<4; ++i) {
        P += B[i] * BUCP[i];
        dPu += B[i] * DUCP[i];
        dPv += D[i] * BUCP[i];
    }
    int level = OsdGetPatchFaceLevel(patchParam);
    dPu *= 3 * level;
    dPv *= 3 * level;

    N = normalize(cross(dPu, dPv));
    dNu = vec3(0);
    dNv = vec3(0);
#endif
}

// ----------------------------------------------------------------------------
// Legacy Gregory
// ----------------------------------------------------------------------------
#if defined(OSD_PATCH_GREGORY) || defined(OSD_PATCH_GREGORY_BOUNDARY)

#if OSD_MAX_VALENCE<=10
uniform float ef[7] = float[](
    0.813008, 0.500000, 0.363636, 0.287505,
    0.238692, 0.204549, 0.179211
);
#else
uniform float ef[27] = float[](
    0.812816, 0.500000, 0.363644, 0.287514,
    0.238688, 0.204544, 0.179229, 0.159657,
    0.144042, 0.131276, 0.120632, 0.111614,
    0.103872, 0.09715, 0.0912559, 0.0860444,
    0.0814022, 0.0772401, 0.0734867, 0.0700842,
    0.0669851, 0.0641504, 0.0615475, 0.0591488,
    0.0569311, 0.0548745, 0.0529621
);
#endif

float cosfn(int n, int j) {
    return cos((2.0f * M_PI * j)/float(n));
}

float sinfn(int n, int j) {
    return sin((2.0f * M_PI * j)/float(n));    
}

#if !defined OSD_MAX_VALENCE || OSD_MAX_VALENCE < 1
#undef OSD_MAX_VALENCE
#define OSD_MAX_VALENCE 4
#endif

struct OsdPerVertexGregory {
    vec3 P;
    ivec3 clipFlag;
    int  valence;
    vec3 e0;
    vec3 e1;
#ifdef OSD_PATCH_GREGORY_BOUNDARY
    int zerothNeighbor;
    vec3 org;
#endif
    vec3 r[OSD_MAX_VALENCE];
};

struct OsdPerPatchVertexGregory {
    ivec3 patchParam;
    vec3 P;
    vec3 Ep;
    vec3 Em;
    vec3 Fp;
    vec3 Fm;
};

#ifndef OSD_NUM_ELEMENTS
#define OSD_NUM_ELEMENTS 3
#endif

uniform samplerBuffer OsdVertexBuffer;
uniform isamplerBuffer OsdValenceBuffer;

vec3 OsdReadVertex(int vertexIndex)
{
    int index = int(OSD_NUM_ELEMENTS * (vertexIndex + OsdBaseVertex()));
    return vec3(texelFetch(OsdVertexBuffer, index).x,
                texelFetch(OsdVertexBuffer, index+1).x,
                texelFetch(OsdVertexBuffer, index+2).x);
}

int OsdReadVertexValence(int vertexID)
{
    int index = int(vertexID * (2 * OSD_MAX_VALENCE + 1));
    return texelFetch(OsdValenceBuffer, index).x;
}

int OsdReadVertexIndex(int vertexID, int valenceVertex)
{
    int index = int(vertexID * (2 * OSD_MAX_VALENCE + 1) + 1 + valenceVertex);
    return texelFetch(OsdValenceBuffer, index).x;
}

uniform isamplerBuffer OsdQuadOffsetBuffer;

int OsdReadQuadOffset(int primitiveID, int offsetVertex)
{
    int index = int(4*primitiveID+OsdGregoryQuadOffsetBase() + offsetVertex);
    return texelFetch(OsdQuadOffsetBuffer, index).x;
}

void
OsdComputePerVertexGregory(int vID, vec3 P, out OsdPerVertexGregory v)
{
    v.clipFlag = ivec3(0);

    int ivalence = OsdReadVertexValence(vID);
    v.valence = ivalence;
    int valence = abs(ivalence);

    vec3 f[OSD_MAX_VALENCE];
    vec3 pos = P;
    vec3 opos = vec3(0);

#ifdef OSD_PATCH_GREGORY_BOUNDARY
    v.org = pos;
    int boundaryEdgeNeighbors[2];
    int currNeighbor = 0;
    int ibefore = 0;
    int zerothNeighbor = 0;
#endif

    for (int i=0; i<valence; ++i) {
        int im = (i+valence-1)%valence;
        int ip = (i+1)%valence;

        int idx_neighbor = OsdReadVertexIndex(vID, 2*i);

#ifdef OSD_PATCH_GREGORY_BOUNDARY
        bool isBoundaryNeighbor = false;
        int valenceNeighbor = OsdReadVertexValence(idx_neighbor);

        if (valenceNeighbor < 0) {
            isBoundaryNeighbor = true;
            if (currNeighbor<2) {
                boundaryEdgeNeighbors[currNeighbor] = idx_neighbor;
            }
            currNeighbor++;
            if (currNeighbor == 1) {
                ibefore = i;
                zerothNeighbor = i;
            } else {
                if (i-ibefore == 1) {
                    int tmp = boundaryEdgeNeighbors[0];
                    boundaryEdgeNeighbors[0] = boundaryEdgeNeighbors[1];
                    boundaryEdgeNeighbors[1] = tmp;
                    zerothNeighbor = i;
                }
            }
        }
#endif

        vec3 neighbor = OsdReadVertex(idx_neighbor);

        int idx_diagonal = OsdReadVertexIndex(vID, 2*i + 1);
        vec3 diagonal = OsdReadVertex(idx_diagonal);

        int idx_neighbor_p = OsdReadVertexIndex(vID, 2*ip);
        vec3 neighbor_p = OsdReadVertex(idx_neighbor_p);

        int idx_neighbor_m = OsdReadVertexIndex(vID, 2*im);
        vec3 neighbor_m = OsdReadVertex(idx_neighbor_m);

        int idx_diagonal_m = OsdReadVertexIndex(vID, 2*im + 1);
        vec3 diagonal_m = OsdReadVertex(idx_diagonal_m);

        f[i] = (pos * float(valence) + (neighbor_p + neighbor)*2.0f + diagonal) / (float(valence)+5.0f);

        opos += f[i];
        v.r[i] = (neighbor_p-neighbor_m)/3.0f + (diagonal - diagonal_m)/6.0f;
    }

    opos /= valence;
    v.P = vec4(opos, 1.0f).xyz;

    vec3 e;
    v.e0 = vec3(0);
    v.e1 = vec3(0);

    for(int i=0; i<valence; ++i) {
        int im = (i + valence -1) % valence;
        e = 0.5f * (f[i] + f[im]);
        v.e0 += cosfn(valence, i)*e;
        v.e1 += sinfn(valence, i)*e;
    }
    v.e0 *= ef[valence - 3];
    v.e1 *= ef[valence - 3];

#ifdef OSD_PATCH_GREGORY_BOUNDARY
    v.zerothNeighbor = zerothNeighbor;
    if (currNeighbor == 1) {
        boundaryEdgeNeighbors[1] = boundaryEdgeNeighbors[0];
    }

    if (ivalence < 0) {
        if (valence > 2) {
            v.P = (OsdReadVertex(boundaryEdgeNeighbors[0]) +
                   OsdReadVertex(boundaryEdgeNeighbors[1]) +
                   4.0f * pos)/6.0f;
        } else {
            v.P = pos;
        }

        v.e0 = (OsdReadVertex(boundaryEdgeNeighbors[0]) -
                OsdReadVertex(boundaryEdgeNeighbors[1]))/6.0;

        float k = float(float(valence) - 1.0f);    //k is the number of faces
        float c = cos(M_PI/k);
        float s = sin(M_PI/k);
        float gamma = -(4.0f*s)/(3.0f*k+c);
        float alpha_0k = -((1.0f+2.0f*c)*sqrt(1.0f+c))/((3.0f*k+c)*sqrt(1.0f-c));
        float beta_0 = s/(3.0f*k + c);

        int idx_diagonal = OsdReadVertexIndex(vID, 2*zerothNeighbor + 1);
        vec3 diagonal = OsdReadVertex(idx_diagonal);

        v.e1 = gamma * pos +
            alpha_0k * OsdReadVertex(boundaryEdgeNeighbors[0]) +
            alpha_0k * OsdReadVertex(boundaryEdgeNeighbors[1]) +
            beta_0 * diagonal;

        for (int x=1; x<valence - 1; ++x) {
            int curri = ((x + zerothNeighbor)%valence);
            float alpha = (4.0f*sin((M_PI * float(x))/k))/(3.0f*k+c);
            float beta = (sin((M_PI * float(x))/k) + sin((M_PI * float(x+1))/k))/(3.0f*k+c);

            int idx_neighbor = OsdReadVertexIndex(vID, 2*curri);
            vec3 neighbor = OsdReadVertex(idx_neighbor);

            idx_diagonal = OsdReadVertexIndex(vID, 2*curri + 1);
            diagonal = OsdReadVertex(idx_diagonal);

            v.e1 += alpha * neighbor + beta * diagonal;
        }

        v.e1 /= 3.0f;
    }
#endif
}

void
OsdComputePerPatchVertexGregory(ivec3 patchParam, int ID, int primitiveID,
                                in OsdPerVertexGregory v[4],
                                out OsdPerPatchVertexGregory result)
{
    result.patchParam = patchParam;
    result.P = v[ID].P;

    int i = ID;
    int ip = (i+1)%4;
    int im = (i+3)%4;
    int valence = abs(v[i].valence);
    int n = valence;

    int start = OsdReadQuadOffset(primitiveID, i) & 0xff;
    int prev = (OsdReadQuadOffset(primitiveID, i) >> 8) & 0xff;

    int start_m = OsdReadQuadOffset(primitiveID, im) & 0xff;
    int prev_p = (OsdReadQuadOffset(primitiveID, ip) >> 8) & 0xff;

    int np = abs(v[ip].valence);
    int nm = abs(v[im].valence);

    // Control Vertices based on :
    // "Approximating Subdivision Surfaces with Gregory Patches
    //  for Hardware Tessellation"
    // Loop, Schaefer, Ni, Castano (ACM ToG Siggraph Asia 2009)
    //
    //  P3         e3-      e2+         E2
    //     O--------O--------O--------O
    //     |        |        |        |
    //     |        |        |        |
    //     |        | f3-    | f2+    |
    //     |        O        O        |
    // e3+ O------O            O------O e2-
    //     |     f3+          f2-     |
    //     |                          |
    //     |                          |
    //     |      f0-         f1+     |
    // e0- O------O            O------O e1+
    //     |        O        O        |
    //     |        | f0+    | f1-    |
    //     |        |        |        |
    //     |        |        |        |
    //     O--------O--------O--------O
    //  P0         e0+      e1-         E1
    //

#ifdef OSD_PATCH_GREGORY_BOUNDARY
    vec3 Em_ip;
    if (v[ip].valence < -2) {
        int j = (np + prev_p - v[ip].zerothNeighbor) % np;
        Em_ip = v[ip].P + cos((M_PI*j)/float(np-1))*v[ip].e0 + sin((M_PI*j)/float(np-1))*v[ip].e1;
    } else {
        Em_ip = v[ip].P + v[ip].e0*cosfn(np, prev_p ) + v[ip].e1*sinfn(np, prev_p);
    }

    vec3 Ep_im;
    if (v[im].valence < -2) {
        int j = (nm + start_m - v[im].zerothNeighbor) % nm;
        Ep_im = v[im].P + cos((M_PI*j)/float(nm-1))*v[im].e0 + sin((M_PI*j)/float(nm-1))*v[im].e1;
    } else {
        Ep_im = v[im].P + v[im].e0*cosfn(nm, start_m) + v[im].e1*sinfn(nm, start_m);
    }

    if (v[i].valence < 0) {
        n = (n-1)*2;
    }
    if (v[im].valence < 0) {
        nm = (nm-1)*2;
    }
    if (v[ip].valence < 0) {
        np = (np-1)*2;
    }

    if (v[i].valence > 2) {
        result.Ep = v[i].P + v[i].e0*cosfn(n, start) + v[i].e1*sinfn(n, start);
        result.Em = v[i].P + v[i].e0*cosfn(n, prev ) + v[i].e1*sinfn(n, prev);

        float s1=3-2*cosfn(n,1)-cosfn(np,1);
        float s2=2*cosfn(n,1);

        result.Fp = (cosfn(np,1)*v[i].P + s1*result.Ep + s2*Em_ip + v[i].r[start])/3.0f;
        s1 = 3.0f-2.0f*cos(2.0f*M_PI/float(n))-cos(2.0f*M_PI/float(nm));
        result.Fm = (cosfn(nm,1)*v[i].P + s1*result.Em + s2*Ep_im - v[i].r[prev])/3.0f;

    } else if (v[i].valence < -2) {
        int j = (valence + start - v[i].zerothNeighbor) % valence;

        result.Ep = v[i].P + cos((M_PI*j)/float(valence-1))*v[i].e0 + sin((M_PI*j)/float(valence-1))*v[i].e1;
        j = (valence + prev - v[i].zerothNeighbor) % valence;
        result.Em = v[i].P + cos((M_PI*j)/float(valence-1))*v[i].e0 + sin((M_PI*j)/float(valence-1))*v[i].e1;

        vec3 Rp = ((-2.0f * v[i].org - 1.0f * v[im].org) + (2.0f * v[ip].org + 1.0f * v[(i+2)%4].org))/3.0f;
        vec3 Rm = ((-2.0f * v[i].org - 1.0f * v[ip].org) + (2.0f * v[im].org + 1.0f * v[(i+2)%4].org))/3.0f;

        float s1 = 3-2*cosfn(n,1)-cosfn(np,1);
        float s2 = 2*cosfn(n,1);

        result.Fp = (cosfn(np,1)*v[i].P + s1*result.Ep + s2*Em_ip + v[i].r[start])/3.0f;
        s1 = 3.0f-2.0f*cos(2.0f*M_PI/float(n))-cos(2.0f*M_PI/float(nm));
        result.Fm = (cosfn(nm,1)*v[i].P + s1*result.Em + s2*Ep_im - v[i].r[prev])/3.0f;

        if (v[im].valence < 0) {
            s1 = 3-2*cosfn(n,1)-cosfn(np,1);
            result.Fp = result.Fm = (cosfn(np,1)*v[i].P + s1*result.Ep + s2*Em_ip + v[i].r[start])/3.0f;
        } else if (v[ip].valence < 0) {
            s1 = 3.0f-2.0f*cos(2.0f*M_PI/n)-cos(2.0f*M_PI/nm);
            result.Fm = result.Fp = (cosfn(nm,1)*v[i].P + s1*result.Em + s2*Ep_im - v[i].r[prev])/3.0f;
        }

    } else if (v[i].valence == -2) {
        result.Ep = (2.0f * v[i].org + v[ip].org)/3.0f;
        result.Em = (2.0f * v[i].org + v[im].org)/3.0f;
        result.Fp = result.Fm = (4.0f * v[i].org + v[(i+2)%n].org + 2.0f * v[ip].org + 2.0f * v[im].org)/9.0f;
    }

#else // not OSD_PATCH_GREGORY_BOUNDARY

    result.Ep = v[i].P + v[i].e0 * cosfn(n, start) + v[i].e1*sinfn(n, start);
    result.Em = v[i].P + v[i].e0 * cosfn(n, prev ) + v[i].e1*sinfn(n, prev);

    vec3 Em_ip = v[ip].P + v[ip].e0 * cosfn(np, prev_p ) + v[ip].e1*sinfn(np, prev_p);
    vec3 Ep_im = v[im].P + v[im].e0 * cosfn(nm, start_m) + v[im].e1*sinfn(nm, start_m);

    float s1 = 3-2*cosfn(n,1)-cosfn(np,1);
    float s2 = 2*cosfn(n,1);

    result.Fp = (cosfn(np,1)*v[i].P + s1*result.Ep + s2*Em_ip + v[i].r[start])/3.0f;
    s1 = 3.0f-2.0f*cos(2.0f*M_PI/float(n))-cos(2.0f*M_PI/float(nm));
    result.Fm = (cosfn(nm,1)*v[i].P + s1*result.Em + s2*Ep_im - v[i].r[prev])/3.0f;
#endif
}

#endif  // OSD_PATCH_GREGORY || OSD_PATCH_GREGORY_BOUNDARY
