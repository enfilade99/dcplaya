/**
 * @file    pulse.c
 * @brief   DC99 visualizer "pulse" : a lit planet whose surface is pushed
 *          out by the music. The bass swells its middle, the higher notes
 *          raise spikes towards the poles; a glowing grid lies over it and
 *          the camera circles it.
 */

#include "dc99vis.h"

#define PU_LAT 12
#define PU_LON 20

static base_t pu;
static mesh_t pu_mesh;
static float pu_dir[PU_LAT + 1][PU_LON][3]; /* unit directions */
static float pu_yaw, pu_speed;

static int pulse_start(void)
{
  int j, i;
  pu.ready = 0;
  if (mesh_alloc(&pu_mesh, "dc99 pulse", (PU_LAT + 1) * PU_LON,
		 PU_LAT * PU_LON * 2)) {
    return -1;
  }
  for (j = 0; j <= PU_LAT; ++j) {
    const float th = j * (MF_PI / PU_LAT);
    for (i = 0; i < PU_LON; ++i) {
      const float ph = i * (2 * MF_PI / PU_LON);
      pu_dir[j][i][0] = Sin(th) * Cos(ph);
      pu_dir[j][i][1] = -Cos(th);
      pu_dir[j][i][2] = Sin(th) * Sin(ph);
      mesh_vtx(&pu_mesh, pu_dir[j][i][0], pu_dir[j][i][1], pu_dir[j][i][2]);
    }
  }
  for (j = 0; j < PU_LAT; ++j) {
    for (i = 0; i < PU_LON; ++i) {
      const int i2 = (i + 1) % PU_LON;
      mesh_quad(&pu_mesh, j * PU_LON + i, j * PU_LON + i2,
		(j + 1) * PU_LON + i2, (j + 1) * PU_LON + i);
    }
  }
  mesh_finish(&pu_mesh);
  mesh_quad_borders(&pu_mesh);
  pu_yaw = 0;
  pu_speed = 0.3f;
  pu.t = 0;
  pu.beats = 0;
  pu.ready = 1;
  return 0;
}

static int pulse_stop(void)
{
  pu.ready = 0;
  mesh_free(&pu_mesh);
  return 0;
}

static int pulse_process(viewport_t * vp, matrix_t proj, int ms)
{
  const float s = base_process(&pu, vp, proj, ms);
  music_t * mu = &pu.mu;
  vtx_t * v;
  tri_t * t;
  int j, i, f;
  /* the light comes from the top left, in front */
  const float lx = -0.45f, ly = -0.7f, lz = -0.55f;
  const float hue = pu.t * 0.02f;

  if (!pu.ready) return -1;

  pu_speed = pu_speed * 0.95f + (0.2f + mu->loud * 0.8f) * 0.05f;
  pu_yaw += s * pu_speed;
  if (mu->beat && !(pu.beats & 3)) look_new_border(pu.tex);

  v = pu_mesh.obj.vtx;
  for (j = 0; j <= PU_LAT; ++j) {
    /* bass at the equator, high notes at the poles */
    const int d = j < PU_LAT / 2 ? PU_LAT / 2 - j : j - PU_LAT / 2;
    const int b = d * (mu->n - 1) / (PU_LAT / 2);
    const float l = mu->lv[b];
    for (i = 0; i < PU_LON; ++i, ++v) {
      float r = 0.72f + mu->bass * 0.18f + mu->beat_glow * 0.08f;
      if (j == 0 || j == PU_LAT) r += l * 0.12f; /* round poles */
      else if ((i + j) & 1) r += l * 0.42f;      /* spikes */
      else r += l * 0.12f;
      v->x = pu_dir[j][i][0] * r;
      v->y = pu_dir[j][i][1] * r;
      v->z = pu_dir[j][i][2] * r;
    }
  }

  /* our own lighting : (b-a)x(c-a) points inwards (winding rule) */
  v = pu_mesh.obj.vtx;
  t = pu_mesh.obj.tri;
  for (f = 0; f < pu_mesh.obj.nbf; ++f, ++t) {
    const vtx_t * a = v + t->a, * b = v + t->b, * c = v + t->c;
    const float ux = b->x - a->x, uy = b->y - a->y, uz = b->z - a->z;
    const float wx = c->x - a->x, wy = c->y - a->y, wz = c->z - a->z;
    const float nx = uy * wz - uz * wy;
    const float ny = uz * wx - ux * wz;
    const float nz = ux * wy - uy * wx;
    const float n2 = nx * nx + ny * ny + nz * nz;
    float lam = 0, rad;
    vtx_t col;
    if (n2 > 1e-12f) {
      lam = -(nx * lx + ny * ly + nz * lz) * ISqrt(n2);
      if (lam < 0) lam = 0;
    }
    /* height of the face : spikes get their own colour */
    rad = (a->x * a->x + a->y * a->y + a->z * a->z);
    look_hsv(&col, hue + rad * 0.18f, 0.7f, 0.22f + lam * 0.78f, 0.95f);
    mesh_face_color(&pu_mesh, f, 0.95f, col.x, col.y, col.z);
  }

  cam_orbit(pu.view, 2.6f, pu_yaw, 0.25f + Sin(pu.t * 0.17f) * 0.25f);
  return 0;
}

static int pulse_render(int opaque)
{
  if (!pu.ready || opaque) return 0;
  mesh_draw_prelit(&pu_mesh, &pu.vp, pu.view, pu.proj, pu.tex, 0);
  return 0;
}

static int pulse_init(any_driver_t * d)
{
  memset(&pu, 0, sizeof(pu));
  pu.tex = look_texture("dc99_pulse");
  if (music_init(&pu.mu, 16)) return -1;
  return -(pu.tex < 0);
}

static int pulse_shutdown(any_driver_t * d)
{
  pulse_stop();
  music_shutdown(&pu.mu);
  return 0;
}

DC99_VIS(pulse_driver, &ridges_driver, "pulse",
	 "A planet that breathes with the music", pulse)
