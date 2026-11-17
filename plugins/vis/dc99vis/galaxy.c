/**
 * @file    galaxy.c
 * @brief   DC99 visualizer "galaxy" : a swarm of cubes orbiting a beating
 *          core. Each cube listens to one band; the beat throws the whole
 *          swarm outwards and it falls back in.
 */

#include "dc99vis.h"

#define GA_N 60

typedef struct {
  float rad, ang, speed, tilt, spin, hue;
  int band;
} star_t;

static base_t ga;
static mesh_t ga_mesh;
static star_t ga_star[GA_N];
static float ga_push, ga_yaw;

static int galaxy_start(void)
{
  int i;
  ga.ready = 0;
  if (mesh_alloc(&ga_mesh, "dc99 galaxy", (GA_N + 1) * BOX_VTX,
		 (GA_N + 1) * BOX_FACES)) {
    return -1;
  }
  for (i = 0; i <= GA_N; ++i) box_add(&ga_mesh);
  mesh_finish(&ga_mesh);
  for (i = 0; i < GA_N; ++i) {
    star_t * st = ga_star + i;
    st->rad = 0.45f + frand() * 0.85f;
    st->ang = frand() * 2 * MF_PI;
    st->speed = (0.35f + frand() * 0.4f) / st->rad;
    st->tilt = (frand() - 0.5f) * 0.9f;
    st->spin = frand() * 6;
    st->hue = st->rad * 0.35f;
    st->band = i % 16;
  }
  ga_push = ga_yaw = 0;
  ga.t = 0;
  ga.beats = 0;
  ga.ready = 1;
  return 0;
}

static int galaxy_stop(void)
{
  ga.ready = 0;
  mesh_free(&ga_mesh);
  return 0;
}

static int galaxy_process(viewport_t * vp, matrix_t proj, int ms)
{
  const float s = base_process(&ga, vp, proj, ms);
  music_t * mu = &ga.mu;
  vtx_t * v;
  vtx_t c, ax, ay;
  int i;

  if (!ga.ready) return -1;

  if (mu->beat) ga_push += 0.35f;
  ga_push *= 1.0f - s * 2.5f;
  if (mu->beat && !(ga.beats & 3)) look_new_border(ga.tex);

  v = ga_mesh.obj.vtx;
  for (i = 0; i < GA_N; ++i, v += BOX_VTX) {
    star_t * st = ga_star + i;
    const float l = mu->lv[st->band];
    const float r = st->rad * (1 + ga_push) + l * 0.25f;
    float x, y, z;
    st->ang += s * st->speed * (1 + mu->loud * 2.5f);
    st->spin += s * (1 + l * 6);
    x = Cos(st->ang) * r;
    z = Sin(st->ang) * r;
    y = z * st->tilt;            /* a tilted orbit */
    c.x = x; c.y = y; c.z = z;
    ax.x = Cos(st->spin); ax.y = 0; ax.z = Sin(st->spin);
    ay.x = 0; ay.y = 1; ay.z = 0;
    {
      const float sz = 0.025f + l * 0.07f;
      box_set(v, &c, &ax, &ay, sz, sz, sz);
    }
    box_color(&ga_mesh, i, st->hue + ga.t * 0.02f, 0.75f - l * 0.4f,
	      0.4f + l * 0.6f, 0.92f);
  }

  /* the core : beats with the bass */
  {
    const float sz = 0.1f + mu->bass * 0.14f + mu->beat_glow * 0.06f;
    c.x = c.y = c.z = 0;
    ax.x = Cos(ga.t * 0.7f); ax.y = 0; ax.z = Sin(ga.t * 0.7f);
    ay.x = 0; ay.y = 1; ay.z = 0;
    box_set(v, &c, &ax, &ay, sz, sz, sz);
    box_color(&ga_mesh, GA_N, ga.t * 0.02f + 0.5f, 0.35f,
	      0.6f + mu->beat_glow * 0.4f, 0.95f);
  }

  ga_yaw += s * (0.1f + mu->loud * 0.3f);
  cam_orbit(ga.view, 2.7f, ga_yaw, 0.5f + Sin(ga.t * 0.13f) * 0.25f);
  return 0;
}

static int galaxy_render(int opaque)
{
  if (!ga.ready || opaque) return 0;
  mesh_draw_prelit(&ga_mesh, &ga.vp, ga.view, ga.proj, ga.tex, 0);
  return 0;
}

static int galaxy_init(any_driver_t * d)
{
  memset(&ga, 0, sizeof(ga));
  ga.tex = look_texture("dc99_galaxy");
  if (music_init(&ga.mu, 16)) return -1;
  return -(ga.tex < 0);
}

static int galaxy_shutdown(any_driver_t * d)
{
  galaxy_stop();
  music_shutdown(&ga.mu);
  return 0;
}

DC99_VIS(galaxy_driver, &helix_driver, "galaxy",
	 "A swarm of cubes around a beating core", galaxy)
