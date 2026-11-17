/**
 * @file    halo.c
 * @brief   DC99 visualizer "halo" : a ring of 3D bars shooting outwards,
 *          the spectrum mirrored left and right, with falling peak marks
 *          pointing inwards. The ring turns and tilts with the music.
 */

#include "dc99vis.h"

#define HA_N   48       /* bars around the ring */
#define HA_R0  0.62f    /* inner radius         */

static base_t ha;
static mesh_t ha_mesh;
static float ha_cos[HA_N], ha_sin[HA_N];
static float ha_spin, ha_speed;

static int halo_start(void)
{
  int i;
  ha.ready = 0;
  if (mesh_alloc(&ha_mesh, "dc99 halo", HA_N * 2 * BOX_VTX,
		 HA_N * 2 * BOX_FACES)) {
    return -1;
  }
  for (i = 0; i < HA_N * 2; ++i) box_add(&ha_mesh);
  mesh_finish(&ha_mesh);
  for (i = 0; i < HA_N; ++i) {
    const float a = i * (2 * MF_PI / HA_N) + MF_PI * 0.5f;
    ha_cos[i] = Cos(a);
    ha_sin[i] = Sin(a);
  }
  ha_spin = 0;
  ha_speed = 0.2f;
  ha.t = 0;
  ha.beats = 0;
  ha.ready = 1;
  return 0;
}

static int halo_stop(void)
{
  ha.ready = 0;
  mesh_free(&ha_mesh);
  return 0;
}

static int halo_process(viewport_t * vp, matrix_t proj, int ms)
{
  const float s = base_process(&ha, vp, proj, ms);
  music_t * mu = &ha.mu;
  vtx_t * v;
  int i;

  if (!ha.ready) return -1;

  ha_speed = ha_speed * 0.95f + (0.15f + mu->loud * 0.9f) * 0.05f;
  if (mu->beat) ha_speed += 0.25f;
  ha_spin += s * ha_speed;
  if (mu->beat && !(ha.beats & 3)) look_new_border(ha.tex);

  v = ha_mesh.obj.vtx;
  for (i = 0; i < HA_N; ++i) {
    /* bar i and its mirror show the same band */
    const int half = HA_N / 2;
    const int b = (i < half ? i : HA_N - 1 - i) * mu->n / half;
    const float l = mu->lv[b], p = mu->pk[b];
    const float len = 0.04f + l * 0.75f;
    vtx_t d, z, c;
    d.x = ha_cos[i]; d.y = ha_sin[i]; d.z = 0;
    z.x = 0; z.y = 0; z.z = 1;

    /* the bar : from the ring outwards */
    c.x = d.x * (HA_R0 + len * 0.5f);
    c.y = d.y * (HA_R0 + len * 0.5f);
    c.z = 0;
    box_set(v, &c, &d, &z, len * 0.5f, 0.035f, 0.032f);
    box_color(&ha_mesh, i, ha.t * 0.04f + (float) b / mu->n * 0.6f,
	      0.8f - l * 0.3f, 0.35f + l * 0.6f + ha.mu.beat_glow * 0.2f, 0.92f);
    v += BOX_VTX;

    /* its peak : a short mark pointing inwards */
    c.x = d.x * (HA_R0 - 0.05f - p * 0.3f);
    c.y = d.y * (HA_R0 - 0.05f - p * 0.3f);
    box_set(v, &c, &d, &z, 0.025f, 0.02f, 0.02f);
    box_color(&ha_mesh, HA_N + i, 0.15f, 0.2f, 0.4f + p * 0.6f, 0.9f);
    v += BOX_VTX;
  }

  {
    matrix_t model, view;
    MtxIdentity(model);
    MtxRotateZ(model, ha_spin);
    cam_orbit(view, 2.5f - mu->bass * 0.25f, Sin(ha.t * 0.31f) * 0.55f,
	      Sin(ha.t * 0.23f) * 0.4f);
    cam_local(ha.view, model, view);
  }
  return 0;
}

static int halo_render(int opaque)
{
  if (!ha.ready || opaque) return 0;
  mesh_draw_prelit(&ha_mesh, &ha.vp, ha.view, ha.proj, ha.tex, 0);
  return 0;
}

static int halo_init(any_driver_t * d)
{
  memset(&ha, 0, sizeof(ha));
  ha.tex = look_texture("dc99_halo");
  if (music_init(&ha.mu, 24)) return -1;
  return -(ha.tex < 0);
}

static int halo_shutdown(any_driver_t * d)
{
  halo_stop();
  music_shutdown(&ha.mu);
  return 0;
}

DC99_VIS(halo_driver, &pulse_driver, "halo",
	 "A ring of bars bursting outwards", halo)
