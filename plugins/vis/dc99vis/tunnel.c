/**
 * @file    tunnel.c
 * @brief   DC99 visualizer "tunnel" : fly through a winding tube. Each ring
 *          of the tube carries the music of the moment it was made, so
 *          the walls are the spectrum rushing past.
 */

#include "dc99vis.h"

#define TU_R    28      /* rings          */
#define TU_N    16      /* sides per ring */
#define TU_DZ   0.30f   /* ring spacing   */
#define TU_NEAR 0.78f  /* - TU_DZ stays past the near plane (0.29) */

static base_t tu;
static mesh_t tu_mesh;
static float tu_hist[TU_R][TU_N]; /* music of each ring, [0] = nearest */
static float tu_travel, tu_phase, tu_roll, tu_speed;
static float tu_cos[TU_N], tu_sin[TU_N];
static int tu_head;

static float path_x(float z) { return Sin(z * 0.33f) * 0.55f + Sin(z * 0.11f) * 0.4f; }
static float path_y(float z) { return Cos(z * 0.27f) * 0.38f; }

static int tunnel_start(void)
{
  int k, i;
  tu.ready = 0;
  if (mesh_alloc(&tu_mesh, "dc99 tunnel", TU_R * TU_N,
		 (TU_R - 1) * TU_N * 2)) {
    return -1;
  }
  for (i = 0; i < TU_N; ++i) {
    const float a = i * (2 * MF_PI / TU_N);
    tu_cos[i] = Cos(a);
    tu_sin[i] = Sin(a);
  }
  for (k = 0; k < TU_R; ++k) {
    for (i = 0; i < TU_N; ++i) {
      mesh_vtx(&tu_mesh, tu_cos[i], tu_sin[i], TU_NEAR + k * TU_DZ);
      tu_hist[k][i] = 0;
    }
  }
  /* seen from inside : quads wound the other way round */
  for (k = 0; k < TU_R - 1; ++k) {
    for (i = 0; i < TU_N; ++i) {
      const int i2 = (i + 1) % TU_N;
      mesh_quad(&tu_mesh, k * TU_N + i, k * TU_N + i2,
		(k + 1) * TU_N + i2, (k + 1) * TU_N + i);
    }
  }
  mesh_finish(&tu_mesh);
  mesh_quad_borders(&tu_mesh);
  tu_travel = tu_phase = tu_roll = 0;
  tu_speed = 1;
  tu_head = 0;
  tu.t = 0;
  tu.beats = 0;
  tu.ready = 1;
  return 0;
}

static int tunnel_stop(void)
{
  tu.ready = 0;
  mesh_free(&tu_mesh);
  return 0;
}

static int tunnel_process(viewport_t * vp, matrix_t proj, int ms)
{
  const float s = base_process(&tu, vp, proj, ms);
  music_t * mu = &tu.mu;
  int k, i;
  vtx_t * v;

  if (!tu.ready) return -1;

  /* faster with louder music, a kick on each beat */
  tu_speed = tu_speed * 0.92f + (1.4f + mu->loud * 4.0f) * 0.08f;
  if (mu->beat) tu_speed += 1.5f;
  tu_travel += s * tu_speed;
  tu_phase += s * tu_speed;
  while (tu_phase >= TU_DZ) {
    /* the nearest ring is behind us : a new one far away, with the music
       of now. The history shifts one step towards the eye. */
    tu_phase -= TU_DZ;
    for (k = 0; k < TU_R - 1; ++k) {
      memcpy(tu_hist[k], tu_hist[k + 1], sizeof(tu_hist[k]));
    }
    for (i = 0; i < TU_N; ++i) {
      /* mirrored : the same band on both sides of the ring */
      const int b = (i < TU_N / 2 ? i : TU_N - 1 - i) * mu->n / (TU_N / 2);
      tu_hist[TU_R - 1][i] = mu->lv[b];
    }
    if (mu->beat) look_new_border(tu.tex);
  }
  tu_roll += s * (0.15f + mu->loud * 0.6f);

  v = tu_mesh.obj.vtx;
  for (k = 0; k < TU_R; ++k) {
    const float z = TU_NEAR + k * TU_DZ - tu_phase;
    const float zw = tu_travel + z;
    const float cx = path_x(zw) - path_x(tu_travel);
    const float cy = path_y(zw) - path_y(tu_travel);
    for (i = 0; i < TU_N; ++i, ++v) {
      const float r = 0.62f + tu_hist[k][i] * 0.5f;
      v->x = cx + tu_cos[i] * r;
      v->y = cy + tu_sin[i] * r;
      v->z = z;
    }
  }
  /* each wall panel glows with its music and fades into the distance */
  {
    const float base = tu.t * 0.025f;
    const float glow = mu->beat_glow * 0.25f;
    int f = 0;
    for (k = 0; k < TU_R - 1; ++k) {
      const float fade = 1.0f - (k + tu_phase / TU_DZ) * (0.85f / TU_R);
      for (i = 0; i < TU_N; ++i, f += 2) {
	const float l = tu_hist[k][i];
	vtx_t c;
	look_hsv(&c, base + l * 0.35f + k * 0.012f, 0.75f - l * 0.35f,
		 (0.25f + l * 0.75f + glow) * fade, 1);
	mesh_face_color(&tu_mesh, f, 0.9f, c.x, c.y, c.z);
	mesh_face_color(&tu_mesh, f + 1, 0.9f, c.x * 0.85f, c.y * 0.85f,
			c.z * 0.85f);
      }
    }
  }
  {
    matrix_t m;
    MtxIdentity(m);
    MtxRotateZ(m, tu_roll);
    MtxIdentity(tu.view);
    MtxMult(m, tu.view);
    MtxCopy(tu.view, m);
  }
  return 0;
}

static int tunnel_render(int opaque)
{
  if (!tu.ready || opaque) return 0;
  mesh_draw_prelit(&tu_mesh, &tu.vp, tu.view, tu.proj, tu.tex, 0);
  return 0;
}

static int tunnel_init(any_driver_t * d)
{
  memset(&tu, 0, sizeof(tu));
  tu.tex = look_texture("dc99_tunnel");
  if (music_init(&tu.mu, 16)) return -1;
  return -(tu.tex < 0);
}

static int tunnel_shutdown(any_driver_t * d)
{
  tunnel_stop();
  music_shutdown(&tu.mu);
  return 0;
}

DC99_VIS(tunnel_driver, &city_driver, "tunnel",
	 "Flight through a tunnel made of the music", tunnel)
