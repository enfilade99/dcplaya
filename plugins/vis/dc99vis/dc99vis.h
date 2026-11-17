/**
 * @file    dc99vis.h
 * @brief   DC99 3D visualizers : shared toolkit.
 *
 * One plugin, several visualizers (each one is a vis driver of its own and
 * shows up in the visualizer list by itself). They are all drawn the way
 * the original dcplaya visualizers are : lit triangles carrying the
 * "border tile" texture, so that the edges glow.
 *
 * (C) 2026 DC99. Built on dcplaya by Benjamin Gerard and Vincent Penne.
 */

#ifndef _DC99VIS_H_
#define _DC99VIS_H_

#include <stdlib.h>
#include <string.h>
#include "math_float.h"
#include "dcplaya/config.h"
#include "matrix.h"
#include "vtx.h"
#include "obj3d.h"
#include "draw_object.h"
#include "vis_driver.h"
#include "obj_driver.h"
#include "driver_list.h"
#include "fft.h"
#include "border.h"
#include "draw/texture.h"
#include "draw/vertex.h"
#include "draw/viewport.h"

/* ---------------------------------------------------------------------- */
/* Meshes                                                                  */
/* ---------------------------------------------------------------------- */

typedef struct {
  obj_t obj;      /* what DrawObject* wants                             */
  int maxv, maxf; /* room                                               */
} mesh_t;

/* Make room for nv vertices and nf triangles. 0 on success. */
int mesh_alloc(mesh_t * m, const char * name, int nv, int nf);
void mesh_free(mesh_t * m);

/* Add a vertex, returns its index. */
int mesh_vtx(mesh_t * m, float x, float y, float z);
/* Add a triangle (a, b, c clockwise as seen from the visible side). */
void mesh_tri(mesh_t * m, int a, int b, int c);
/* Add a quad a b c d (clockwise), as two triangles split on a-c. */
void mesh_quad(mesh_t * m, int a, int b, int c, int d);

/* Once every triangle is in : find the triangles that share each edge
 * (an edge with no neighbour, or between faces at a sharp angle, gets a
 * glowing border) and compute the normals. */
void mesh_finish(mesh_t * m);

/* After mesh_finish, for a mesh made only of mesh_quad : every quad gets
 * a glowing border on its four sides (not on its diagonal), so a smooth
 * surface shows as a lit grid. */
void mesh_quad_borders(mesh_t * m);

/* After moving vertices : new normals. */
void mesh_normals(mesh_t * m);

/* An axis aligned box from (x0,y0,z0) to (x1,y1,z1), without its bottom.
 * Returns the index of its first vertex : +0..3 bottom, +4..7 top. */
int mesh_box(mesh_t * m, float x0, float y0, float z0,
	     float x1, float y1, float z1);

/* Colour of one triangle, for mesh_draw_prelit (0..1 each). */
void mesh_face_color(mesh_t * m, int f, float a, float r, float g, float b);
/* Draw with the colour of each triangle, no lighting. */
void mesh_draw_prelit(mesh_t * m, viewport_t * vp, matrix_t local,
		      matrix_t proj, int tex, int opaque);

/* Winding rule of dcplaya's renderer (y goes DOWN the screen): a triangle
 * a b c is drawn when (b-a) x (c-a) points AWAY from the eye. So a closed
 * object seen from outside has that cross product pointing inwards.
 *
 * A box in any orientation : centre c, unit axes ax ay az with
 * az = ax x ay, half sizes hx hy hz. Uses the same 8 vertices / 10
 * triangles as mesh_box (no bottom : the -ay side is open).
 * box_add builds it, box_set moves an existing one (v = its first vertex). */
int box_add(mesh_t * m);
void box_set(vtx_t * v, const vtx_t * c, const vtx_t * ax, const vtx_t * ay,
	     float hx, float hy, float hz);
/* the 10 faces of box number k (built in a row with box_add) */
#define BOX_FACES 10
#define BOX_VTX 8

/* Colour the 10 faces of box number k (first face k * BOX_FACES) as if
 * lit from above : top at full value, sides darker. */
void box_color(mesh_t * m, int k, float h, float sat, float val, float a);

/* Camera on an orbit around the origin : distance, yaw (around y),
 * pitch (positive = looking down from above). */
void cam_orbit(matrix_t v, float dist, float yaw, float pitch);

/* Draw it. tex : texture id, opaque : 0 or 1. */
void mesh_draw(mesh_t * m, viewport_t * vp, matrix_t local, matrix_t proj,
	       int tex, int opaque, const vtx_t * ambient,
	       const vtx_t * light, const vtx_t * color);

/* ---------------------------------------------------------------------- */
/* Music                                                                   */
/* ---------------------------------------------------------------------- */

#define MUSIC_MAX_BANDS 64

typedef struct {
  int n;                          /* number of bands                    */
  fftbands_t * bands;
  float lv[MUSIC_MAX_BANDS];      /* level of each band 0..1, smoothed  */
  float pk[MUSIC_MAX_BANDS];      /* slowly falling peaks               */
  float loud;                     /* average level 0..1                 */
  float bass;                     /* low notes 0..1                     */
  float bass_avg;                 /* their running average              */
  int beat;                       /* 1 on the frame of a beat           */
  float since_beat;               /* seconds                            */
  float beat_glow;                /* 1 at a beat, falls to 0            */
} music_t;

int music_init(music_t * mu, int n);
void music_shutdown(music_t * mu);
void music_update(music_t * mu, float seconds);

/* ---------------------------------------------------------------------- */
/* Looks                                                                   */
/* ---------------------------------------------------------------------- */

/* Border tile texture of our own (name must be unique), or -1. */
int look_texture(const char * name);
/* New random border pattern, as hyperpipe does on a beat. */
void look_new_border(int tex);

/* Colour from a hue 0..1 (wraps), saturation and value 0..1. */
void look_hsv(vtx_t * c, float h, float s, float v, float a);

/* Camera : view matrix for an eye at (x,y,z) turned by yaw (around y) and
 * pitch (around x). The result is multiplied after the model matrix. */
void cam_view(matrix_t v, float x, float y, float z, float yaw, float pitch);

/* local = model * view */
void cam_local(matrix_t local, matrix_t model, matrix_t view);

float fclamp(float v, float lo, float hi);
float frand(void); /* 0..1 */

/* ---------------------------------------------------------------------- */
/* What every visualizer keeps                                             */
/* ---------------------------------------------------------------------- */

typedef struct {
  int ready;
  viewport_t vp;      /* given by dcplaya each frame        */
  matrix_t proj;      /* given by dcplaya each frame        */
  matrix_t view;      /* our camera                         */
  int tex;            /* our border tile texture            */
  music_t mu;
  float t;            /* seconds since start                */
  int beats;          /* beats since start                  */
} base_t;

/* Call from process() : copies what dcplaya gives, reads the music.
 * Returns the seconds since the last frame (0 if not ready). */
float base_process(base_t * b, viewport_t * vp, matrix_t proj, int ms);

/* Load an object of the obj plugin ("torusknot", "spaceship1", ...). */
obj_driver_t * base_object(const char * name);
void base_release(obj_driver_t ** o);

/* Every visualizer file ends with this : a vis driver whose functions are
 * PREFIX_init, _shutdown, _start, _stop, _process, _render(opaque). */
#define DC99_VIS(SYM, NEXT, NAME, DESC, PFX)				\
  static int PFX##_opaque(void) { return PFX##_render(1); }		\
  static int PFX##_translucent(void) { return PFX##_render(0); }	\
  static driver_option_t * PFX##_options(any_driver_t * d, int i,	\
					 driver_option_t * o)		\
  { return o; }								\
  vis_driver_t SYM = {							\
    {									\
      (any_driver_t *) (NEXT), VIS_DRIVER, 0x0100, NAME,		\
      "DC99\0", DESC, 0,						\
      PFX##_init, PFX##_shutdown, PFX##_options, 0			\
    },									\
    PFX##_start, PFX##_stop, PFX##_process,				\
    PFX##_opaque, PFX##_translucent					\
  };

/* The chain of drivers in this plugin, first to last. */
extern vis_driver_t tunnel_driver;
extern vis_driver_t city_driver;
extern vis_driver_t halo_driver;
extern vis_driver_t pulse_driver;
extern vis_driver_t ridges_driver;
extern vis_driver_t galaxy_driver;
extern vis_driver_t helix_driver;

#endif
