/**
 * @file    ridges.c
 * @brief   DC99 visualizer "ridges" : rows of mountain lines, each one the
 *          spectrum of a moment, rolling away into the distance. Only the
 *          crest of each row glows; its dark wall hides the rows behind.
 */

#include "dc99vis.h"

#define RI_ROWS 14
#define RI_COLS 24
#define RI_DZ   0.17f
#define RI_W    2.6f
#define RI_STEP 0.07f

static base_t ri;
static mesh_t ri_mesh;
static float ri_hist[RI_ROWS][RI_COLS + 1]; /* [0] = now */
static float ri_clock;

/* vertex index of row r (0 = nearest), column i : bottom and top */
#define RI_B(r, i) (((r) * (RI_COLS + 1) + (i)) * 2)
#define RI_T(r, i) (RI_B(r, i) + 1)

static int ridges_start(void)
{
  int r, i;
  ri.ready = 0;
  if (mesh_alloc(&ri_mesh, "dc99 ridges", RI_ROWS * (RI_COLS + 1) * 2,
		 RI_ROWS * RI_COLS * 2)) {
    return -1;
  }
  for (r = 0; r < RI_ROWS; ++r) {
    for (i = 0; i <= RI_COLS; ++i) {
      const float x = (i - RI_COLS * 0.5f) * (RI_W / RI_COLS);
      mesh_vtx(&ri_mesh, x, 0, r * RI_DZ);
      mesh_vtx(&ri_mesh, x, -0.02f, r * RI_DZ);
      ri_hist[r][i] = 0;
    }
  }
  /* farthest row first, so the near walls come after and hide them */
  for (r = RI_ROWS - 1; r >= 0; --r) {
    for (i = 0; i < RI_COLS; ++i) {
      mesh_quad(&ri_mesh, RI_B(r, i), RI_T(r, i),
		RI_T(r, i + 1), RI_B(r, i + 1));
    }
  }
  mesh_finish(&ri_mesh);
  /* quad [B T T' B'] = [B T T'] + [B T' B'] : only the crest T-T' glows */
  for (i = 0; i < ri_mesh.obj.nbf; i += 2) {
    ri_mesh.obj.tlk[i].flags = 2;
    ri_mesh.obj.tlk[i + 1].flags = 0;
  }
  ri_clock = 0;
  ri.t = 0;
  ri.beats = 0;
  ri.ready = 1;
  return 0;
}

static int ridges_stop(void)
{
  ri.ready = 0;
  mesh_free(&ri_mesh);
  return 0;
}

static int ridges_process(viewport_t * vp, matrix_t proj, int ms)
{
  const float s = base_process(&ri, vp, proj, ms);
  music_t * mu = &ri.mu;
  vtx_t * v;
  int r, i, f;

  if (!ri.ready) return -1;

  ri_clock += s;
  if (ri_clock >= RI_STEP) {
    ri_clock = 0;
    for (r = RI_ROWS - 1; r > 0; --r) {
      memcpy(ri_hist[r], ri_hist[r - 1], sizeof(ri_hist[r]));
    }
  }
  /* the front row : the spectrum, mirrored, taller in the middle */
  for (i = 0; i <= RI_COLS; ++i) {
    const int half = RI_COLS / 2;
    const int d = i < half ? half - i : i - half;
    const int b = d * (mu->n - 1) / half;
    const float bell = 1.0f - (float) d / (half + 2);
    ri_hist[0][i] = mu->lv[b] * (0.35f + bell * 0.75f);
  }
  if (mu->beat && !(ri.beats & 3)) look_new_border(ri.tex);

  v = ri_mesh.obj.vtx;
  for (r = 0; r < RI_ROWS; ++r) {
    for (i = 0; i <= RI_COLS; ++i, v += 2) {
      v[1].y = -0.02f - ri_hist[r][i] * 0.85f;
    }
  }

  /* dark walls, the near rows brighter; colour follows the beat */
  f = 0;
  for (r = RI_ROWS - 1; r >= 0; --r) {
    const float fade = 1.0f - r * (0.75f / RI_ROWS);
    vtx_t c;
    look_hsv(&c, 0.55f + ri.t * 0.015f + r * 0.02f, 0.65f,
	     (0.55f + ri.mu.beat_glow * 0.45f) * fade, 1);
    for (i = 0; i < RI_COLS; ++i, f += 2) {
      mesh_face_color(&ri_mesh, f, 0.96f, c.x, c.y, c.z);
      mesh_face_color(&ri_mesh, f + 1, 0.96f, c.x * 0.4f, c.y * 0.4f,
		      c.z * 0.4f);
    }
  }

  {
    matrix_t model, view;
    MtxIdentity(model);
    MtxTranslate(model, 0, 0.12f, -RI_ROWS * RI_DZ * 0.45f);
    cam_orbit(view, 2.3f, Sin(ri.t * 0.11f) * 0.3f,
	      0.42f + Sin(ri.t * 0.07f) * 0.1f);
    cam_local(ri.view, model, view);
  }
  return 0;
}

static int ridges_render(int opaque)
{
  if (!ri.ready || opaque) return 0;
  mesh_draw_prelit(&ri_mesh, &ri.vp, ri.view, ri.proj, ri.tex, 0);
  return 0;
}

static int ridges_init(any_driver_t * d)
{
  memset(&ri, 0, sizeof(ri));
  ri.tex = look_texture("dc99_ridges");
  if (music_init(&ri.mu, 16)) return -1;
  return -(ri.tex < 0);
}

static int ridges_shutdown(any_driver_t * d)
{
  ridges_stop();
  music_shutdown(&ri.mu);
  return 0;
}

DC99_VIS(ridges_driver, &galaxy_driver, "ridges",
	 "Mountain lines of the music rolling away", ridges)
