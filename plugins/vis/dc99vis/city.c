/**
 * @file    city.c
 * @brief   DC99 visualizer "city" : the classic spectrum bars in 3D. A grid
 *          of towers; the front row is the music now and every row behind
 *          it is a moment earlier, so the city scrolls away from you while
 *          the camera circles it.
 */

#include "dc99vis.h"

#define CI_G     8       /* towers per row, rows */
#define CI_CELL  0.25f
#define CI_SIZE  0.19f
#define CI_STEP  0.09f   /* seconds between rows */

static base_t ci;
static mesh_t ci_row[CI_G];
static float ci_hist[CI_G][CI_G]; /* [row][tower], row 0 = now */
static float ci_clock, ci_yaw, ci_spin;

static int city_start(void)
{
  int r, i;
  ci.ready = 0;
  for (r = 0; r < CI_G; ++r) {
    if (mesh_alloc(&ci_row[r], "dc99 city", CI_G * 8, CI_G * 10)) {
      while (r--) mesh_free(&ci_row[r]);
      return -1;
    }
    for (i = 0; i < CI_G; ++i) {
      const float x = (i - (CI_G - 1) * 0.5f) * CI_CELL - CI_SIZE * 0.5f;
      const float z = (r - (CI_G - 1) * 0.5f) * CI_CELL - CI_SIZE * 0.5f;
      mesh_box(&ci_row[r], x, 0, z, x + CI_SIZE, 0.1f, z + CI_SIZE);
      ci_hist[r][i] = 0;
    }
    mesh_finish(&ci_row[r]);
  }
  ci_clock = ci_yaw = ci_spin = 0;
  ci.t = 0;
  ci.beats = 0;
  ci.ready = 1;
  return 0;
}

static int city_stop(void)
{
  int r;
  ci.ready = 0;
  for (r = 0; r < CI_G; ++r) mesh_free(&ci_row[r]);
  return 0;
}

static int city_process(viewport_t * vp, matrix_t proj, int ms)
{
  const float s = base_process(&ci, vp, proj, ms);
  music_t * mu = &ci.mu;
  int r, i;

  if (!ci.ready) return -1;

  ci_clock += s;
  if (ci_clock >= CI_STEP) {
    ci_clock = 0;
    for (r = CI_G - 1; r > 0; --r) {
      memcpy(ci_hist[r], ci_hist[r - 1], sizeof(ci_hist[r]));
    }
  }
  /* the front row follows the music all the time */
  for (i = 0; i < CI_G; ++i) {
    ci_hist[0][i] = mu->lv[i * mu->n / CI_G];
  }
  for (r = 0; r < CI_G; ++r) {
    vtx_t * v = ci_row[r].obj.vtx;
    /* the newest row in the brightest colour, older rows fade */
    const float fade = 1.0f - r * (0.6f / CI_G);
    for (i = 0; i < CI_G; ++i, v += 8) {
      const float l = ci_hist[r][i];
      const float h = 0.03f + l * 1.1f;
      v[4].y = v[5].y = v[6].y = v[7].y = -h; /* y goes down the screen */
      box_color(&ci_row[r], i, 0.36f - l * 0.36f + ci.t * 0.008f,
		0.8f, (0.35f + l * 0.65f + mu->beat_glow * 0.15f) * fade,
		0.94f);
    }
  }
  if (mu->beat && !(ci.beats & 3)) look_new_border(ci.tex);

  /* the camera circles slowly, faster with the music */
  ci_spin = ci_spin * 0.95f + (0.12f + mu->loud * 0.5f) * 0.05f;
  ci_yaw += s * ci_spin;
  cam_orbit(ci.view, 2.9f, ci_yaw, 0.48f + Sin(ci.t * 0.21f) * 0.1f);
  return 0;
}

static int city_render(int opaque)
{
  int r;
  if (!ci.ready || opaque) return 0;
  for (r = CI_G - 1; r >= 0; --r) {
    mesh_draw_prelit(&ci_row[r], &ci.vp, ci.view, ci.proj, ci.tex, 0);
  }
  return 0;
}

static int city_init(any_driver_t * d)
{
  memset(&ci, 0, sizeof(ci));
  ci.tex = look_texture("dc99_city");
  if (music_init(&ci.mu, 16)) return -1;
  return -(ci.tex < 0);
}

static int city_shutdown(any_driver_t * d)
{
  city_stop();
  music_shutdown(&ci.mu);
  return 0;
}

DC99_VIS(city_driver, &halo_driver, "city", "Spectrum bars as a 3D city", city)
