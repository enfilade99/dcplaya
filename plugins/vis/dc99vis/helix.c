/**
 * @file    helix.c
 * @brief   DC99 visualizer "helix" : a turning double helix. Each rung is
 *          one band of the music and grows from both strands towards the
 *          middle; when the music is loud the rungs meet.
 */

#include "dc99vis.h"

#define HE_N  20        /* rungs                   */
#define HE_R  0.55f     /* radius of the strands   */
#define HE_DY 0.09f     /* distance between rungs  */

static base_t he;
static mesh_t he_mesh;
static float he_turn, he_speed;

static int helix_start(void)
{
  int i;
  he.ready = 0;
  if (mesh_alloc(&he_mesh, "dc99 helix", HE_N * 4 * BOX_VTX,
		 HE_N * 4 * BOX_FACES)) {
    return -1;
  }
  for (i = 0; i < HE_N * 4; ++i) box_add(&he_mesh);
  mesh_finish(&he_mesh);
  he_turn = 0;
  he_speed = 0.6f;
  he.t = 0;
  he.beats = 0;
  he.ready = 1;
  return 0;
}

static int helix_stop(void)
{
  he.ready = 0;
  mesh_free(&he_mesh);
  return 0;
}

static int helix_process(viewport_t * vp, matrix_t proj, int ms)
{
  const float s = base_process(&he, vp, proj, ms);
  music_t * mu = &he.mu;
  vtx_t * v = he_mesh.obj.vtx;
  vtx_t up;
  int k, side;

  if (!he.ready) return -1;

  he_speed = he_speed * 0.94f + (0.5f + mu->loud * 2.2f) * 0.06f;
  if (mu->beat) he_speed += 0.6f;
  he_turn += s * he_speed;
  if (mu->beat && !(he.beats & 3)) look_new_border(he.tex);

  up.x = 0; up.y = 1; up.z = 0;
  for (k = 0; k < HE_N; ++k) {
    const float a = k * 0.42f + he_turn;
    const float y = (k - (HE_N - 1) * 0.5f) * HE_DY;
    const int b = k * mu->n / HE_N;
    const float l = mu->lv[b];
    const float hue = he.t * 0.03f + (float) k / HE_N * 0.5f;
    for (side = 0; side < 2; ++side) {
      const float sg = side ? -1.0f : 1.0f;
      vtx_t d, c;
      int box = (k * 2 + side) * 2;
      d.x = Cos(a) * sg; d.y = 0; d.z = Sin(a) * sg;

      /* the strand : a bead */
      c.x = d.x * HE_R; c.y = y; c.z = d.z * HE_R;
      box_set(v, &c, &d, &up, 0.075f, 0.05f, 0.075f);
      box_color(&he_mesh, box, 0.52f + he.t * 0.01f, 0.45f,
		0.75f + he.mu.beat_glow * 0.25f, 0.96f);
      v += BOX_VTX;

      /* half a rung, from the strand inwards */
      {
	const float len = 0.04f + l * (HE_R - 0.08f);
	c.x = d.x * (HE_R - 0.07f - len * 0.5f);
	c.z = d.z * (HE_R - 0.07f - len * 0.5f);
	box_set(v, &c, &d, &up, len * 0.5f, 0.035f, 0.04f);
	box_color(&he_mesh, box + 1, hue, 0.85f - l * 0.3f, 0.5f + l * 0.5f,
		  0.95f);
	v += BOX_VTX;
      }
    }
  }

  {
    matrix_t model, view;
    MtxIdentity(model);
    MtxRotateZ(model, 0.45f);
    cam_orbit(view, 2.5f, Sin(he.t * 0.19f) * 0.6f,
	      0.15f + Sin(he.t * 0.13f) * 0.15f);
    cam_local(he.view, model, view);
  }
  return 0;
}

static int helix_render(int opaque)
{
  if (!he.ready || opaque) return 0;
  mesh_draw_prelit(&he_mesh, &he.vp, he.view, he.proj, he.tex, 0);
  return 0;
}

static int helix_init(any_driver_t * d)
{
  memset(&he, 0, sizeof(he));
  he.tex = look_texture("dc99_helix");
  if (music_init(&he.mu, 24)) return -1;
  return -(he.tex < 0);
}

static int helix_shutdown(any_driver_t * d)
{
  helix_stop();
  music_shutdown(&he.mu);
  return 0;
}

DC99_VIS(helix_driver, 0, "helix", "A turning double helix of the music",
	 helix)
