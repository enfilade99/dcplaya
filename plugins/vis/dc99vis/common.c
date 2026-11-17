/**
 * @file    common.c
 * @brief   DC99 3D visualizers : shared toolkit (see dc99vis.h).
 */

#include "dc99vis.h"

extern short int_decibel[];

/* ---------------------------------------------------------------------- */
/* Meshes                                                                  */
/* ---------------------------------------------------------------------- */

int mesh_alloc(mesh_t * m, const char * name, int nv, int nf)
{
  memset(m, 0, sizeof(*m));
  m->obj.name = name;
  /* one more face : the invisible "nobody" neighbour of open edges */
  m->obj.vtx = (vtx_t *) malloc(sizeof(vtx_t) * (nv + 1));
  m->obj.tri = (tri_t *) malloc(sizeof(tri_t) * (nf + 1));
  m->obj.tlk = (tlk_t *) malloc(sizeof(tlk_t) * (nf + 1));
  m->obj.nvx = (vtx_t *) malloc(sizeof(vtx_t) * (nf + 1));
  if (!m->obj.vtx || !m->obj.tri || !m->obj.tlk || !m->obj.nvx) {
    mesh_free(m);
    return -1;
  }
  m->maxv = nv;
  m->maxf = nf;
  return 0;
}

void mesh_free(mesh_t * m)
{
  if (m->obj.vtx) free(m->obj.vtx);
  if (m->obj.tri) free(m->obj.tri);
  if (m->obj.tlk) free(m->obj.tlk);
  if (m->obj.nvx) free(m->obj.nvx);
  memset(m, 0, sizeof(*m));
}

int mesh_vtx(mesh_t * m, float x, float y, float z)
{
  vtx_t * v;
  if (m->obj.nbv >= m->maxv) return m->maxv - 1;
  v = m->obj.vtx + m->obj.nbv;
  v->x = x; v->y = y; v->z = z; v->w = 1.0f;
  return m->obj.nbv++;
}

void mesh_tri(mesh_t * m, int a, int b, int c)
{
  tri_t * t;
  if (m->obj.nbf >= m->maxf) return;
  t = m->obj.tri + m->obj.nbf++;
  t->a = a; t->b = b; t->c = c; t->flags = 0;
}

void mesh_quad(mesh_t * m, int a, int b, int c, int d)
{
  mesh_tri(m, a, b, c);
  mesh_tri(m, a, c, d);
}

int mesh_box(mesh_t * m, float x0, float y0, float z0,
	     float x1, float y1, float z1)
{
  int b = mesh_vtx(m, x0, y0, z0);
  mesh_vtx(m, x1, y0, z0);
  mesh_vtx(m, x1, y0, z1);
  mesh_vtx(m, x0, y0, z1);
  mesh_vtx(m, x0, y1, z0);
  mesh_vtx(m, x1, y1, z0);
  mesh_vtx(m, x1, y1, z1);
  mesh_vtx(m, x0, y1, z1);
  /* top, then the four sides; wound for a box whose top is "up" (y1 < y0)
     and seen from outside (see the winding rule in dc99vis.h) */
  mesh_quad(m, b+4, b+7, b+6, b+5);
  mesh_quad(m, b+0, b+4, b+5, b+1);
  mesh_quad(m, b+1, b+5, b+6, b+2);
  mesh_quad(m, b+2, b+6, b+7, b+3);
  mesh_quad(m, b+3, b+7, b+4, b+0);
  return b;
}

int box_add(mesh_t * m)
{
  return mesh_box(m, -1, 1, -1, 1, -1, 1);
}

static void cross(vtx_t * r, const vtx_t * a, const vtx_t * b)
{
  r->x = a->y * b->z - a->z * b->y;
  r->y = a->z * b->x - a->x * b->z;
  r->z = a->x * b->y - a->y * b->x;
}

void box_set(vtx_t * v, const vtx_t * c, const vtx_t * ax, const vtx_t * ay,
	     float hx, float hy, float hz)
{
  /* local corners as in mesh_box(-hx, hy, -hz, hx, -hy, hz) : the "top"
     is at -hy along ay */
  static const signed char lx[8] = { -1, 1, 1, -1, -1, 1, 1, -1 };
  static const signed char ly[8] = { 1, 1, 1, 1, -1, -1, -1, -1 };
  static const signed char lz[8] = { -1, -1, 1, 1, -1, -1, 1, 1 };
  vtx_t az;
  int i;
  cross(&az, ax, ay);
  for (i = 0; i < 8; ++i, ++v) {
    const float x = lx[i] * hx, y = ly[i] * hy, z = lz[i] * hz;
    v->x = c->x + x * ax->x + y * ay->x + z * az.x;
    v->y = c->y + x * ax->y + y * ay->y + z * az.y;
    v->z = c->z + x * ax->z + y * ay->z + z * az.z;
    v->w = 1;
  }
}

void box_color(mesh_t * m, int k, float h, float sat, float val, float a)
{
  static const float shade[5] = { 1.0f, 0.62f, 0.8f, 0.5f, 0.72f };
  const int f0 = k * BOX_FACES;
  int i;
  for (i = 0; i < 5; ++i) {
    vtx_t c;
    look_hsv(&c, h, sat, val * shade[i], a);
    mesh_face_color(m, f0 + i * 2, a, c.x, c.y, c.z);
    mesh_face_color(m, f0 + i * 2 + 1, a, c.x, c.y, c.z);
  }
}

void cam_orbit(matrix_t v, float dist, float yaw, float pitch)
{
  const float ex = Sin(yaw) * Cos(pitch) * dist;
  const float ey = -Sin(pitch) * dist;
  const float ez = -Cos(yaw) * Cos(pitch) * dist;
  MtxIdentity(v);
  MtxTranslate(v, -ex, -ey, -ez);
  MtxRotateY(v, yaw);
  MtxRotateX(v, pitch);
}

void mesh_normals(mesh_t * m)
{
  obj3d_build_normals(&m->obj);
}

static int edge_vertex(const tri_t * t, int j)
{
  return (&t->a)[j];
}

/* Faces around each vertex, to find neighbours quickly. */
void mesh_finish(mesh_t * m)
{
  obj_t * o = &m->obj;
  const int nf = o->nbf, nv = o->nbv;
  int * start, * list;
  int i, j, k;

  o->static_nbv = nv;
  o->static_nbf = nf;

  start = (int *) calloc(nv + 1, sizeof(int));
  list = (int *) malloc(sizeof(int) * nf * 3 + 1);

  /* the special last face : invisible, everybody's missing neighbour */
  o->tri[nf].a = o->tri[nf].b = o->tri[nf].c = 0;
  o->tri[nf].flags = 1;
  o->tlk[nf].a = o->tlk[nf].b = o->tlk[nf].c = nf;
  o->tlk[nf].flags = 0;

  obj3d_build_normals(o);

  if (start && list) {
    for (i = 0; i < nf; ++i)
      for (j = 0; j < 3; ++j)
	++start[edge_vertex(o->tri + i, j) + 1];
    for (i = 0; i < nv; ++i)
      start[i + 1] += start[i];
    for (i = 0; i < nf; ++i)
      for (j = 0; j < 3; ++j) {
	const int v = edge_vertex(o->tri + i, j);
	list[start[v]++] = i;
      }
    /* start[v] now points after v's list : step back */
    for (i = nv; i > 0; --i)
      start[i] = start[i - 1];
    start[0] = 0;
  }

  for (i = 0; i < nf; ++i) {
    tri_t * t = o->tri + i;
    int * lk = &o->tlk[i].a;
    o->tlk[i].flags = 0;
    for (j = 0; j < 3; ++j) {
      const int a = edge_vertex(t, j);
      const int b = edge_vertex(t, (j + 1) % 3);
      int found = nf;
      if (start && list) {
	/* a face that has the edge b -> a */
	for (k = start[b]; k < start[b + 1]; ++k) {
	  const int f = list[k];
	  const tri_t * u = o->tri + f;
	  int e;
	  if (f == i) continue;
	  for (e = 0; e < 3; ++e) {
	    if (edge_vertex(u, e) == b && edge_vertex(u, (e + 1) % 3) == a) {
	      found = f;
	      break;
	    }
	  }
	  if (found != nf) break;
	}
      }
      lk[j] = found;
      if (found == nf) {
	o->tlk[i].flags |= 1 << j;
      } else {
	/* a sharp fold glows too (box edges), a flat one does not */
	const vtx_t * n1 = o->nvx + i, * n2 = o->nvx + found;
	const float c = n1->x * n2->x + n1->y * n2->y + n1->z * n2->z;
	if (c <= 0.59f) o->tlk[i].flags |= 1 << j;
      }
    }
  }
  if (start) free(start);
  if (list) free(list);
}

void mesh_quad_borders(mesh_t * m)
{
  int f;
  /* mesh_quad(a,b,c,d) : [a b c] then [a c d]; the diagonal is c-a in the
     first, a-c in the second */
  for (f = 0; f + 1 < m->obj.nbf; f += 2) {
    m->obj.tlk[f].flags |= 1 | 2;
    m->obj.tlk[f + 1].flags |= 2 | 4;
  }
}

static unsigned int c255(float v)
{
  int i = (int) (v * 255.0f);
  return i < 0 ? 0 : (i > 255 ? 255 : i);
}

void mesh_face_color(mesh_t * m, int f, float a, float r, float g, float b)
{
  /* DrawObjectPrelighted reads the colour packed in the normal's w */
  unsigned int c = (c255(a) << 24) | (c255(r) << 16) | (c255(g) << 8) | c255(b);
  *(unsigned int *) &m->obj.nvx[f].w = c;
}

void mesh_draw_prelit(mesh_t * m, viewport_t * vp, matrix_t local,
		      matrix_t proj, int tex, int opaque)
{
  if (!m->obj.nbf || tex <= 0) return;
  m->obj.flags = 0
    | DRAW_NO_FILTER
    | (opaque ? DRAW_OPAQUE : DRAW_TRANSLUCENT)
    | (tex << DRAW_TEXTURE_BIT);
  DrawObjectPrelighted(vp, local, proj, &m->obj);
}

void mesh_draw(mesh_t * m, viewport_t * vp, matrix_t local, matrix_t proj,
	       int tex, int opaque, const vtx_t * ambient,
	       const vtx_t * light, const vtx_t * color)
{
  if (!m->obj.nbf || tex <= 0) return;
  m->obj.flags = 0
    | DRAW_NO_FILTER
    | (opaque ? DRAW_OPAQUE : DRAW_TRANSLUCENT)
    | (tex << DRAW_TEXTURE_BIT);
  if (light) {
    vtx_t l = *light, a = *ambient, c = *color;
    DrawObjectLighted(vp, local, proj, &m->obj, &a, &l, &c);
  } else {
    DrawObjectFrontLighted(vp, local, proj, &m->obj, ambient, color);
  }
}

/* ---------------------------------------------------------------------- */
/* Music                                                                   */
/* ---------------------------------------------------------------------- */

int music_init(music_t * mu, int n)
{
  memset(mu, 0, sizeof(*mu));
  if (n > MUSIC_MAX_BANDS) n = MUSIC_MAX_BANDS;
  mu->n = n;
  mu->bands = fft_create_bands(n, 0);
  mu->bass_avg = 0.2f;
  return mu->bands ? 0 : -1;
}

void music_shutdown(music_t * mu)
{
  if (mu->bands) free(mu->bands);
  mu->bands = 0;
}

static float band_level(int v)
{
  int d = v - 150;
  if (d < 0) d = 0;
  return int_decibel[d >> 3] * (1.0f / 32768.0f);
}

void music_update(music_t * mu, float seconds)
{
  int i, nlow;
  float sum = 0, low = 0;
  const float fall = seconds * 1.8f;
  const float pfall = seconds * 0.45f;

  if (!mu->bands) return;
  fft_fill_bands(mu->bands);

  for (i = 0; i < mu->n; ++i) {
    float l = band_level(mu->bands->band[i].v);
    if (l > 1) l = 1;
    if (l < mu->lv[i] - fall) l = mu->lv[i] - fall; /* fast up, slow down */
    if (l < 0) l = 0;
    mu->lv[i] = l;
    if (l > mu->pk[i]) mu->pk[i] = l;
    else {
      mu->pk[i] -= pfall;
      if (mu->pk[i] < l) mu->pk[i] = l;
    }
    sum += l;
  }
  mu->loud = sum / mu->n;

  /* the bottom sixth of the bands for the beat */
  nlow = mu->n / 6;
  if (nlow < 1) nlow = 1;
  for (i = 0; i < nlow; ++i) {
    low += band_level(mu->bands->band[i].v);
  }
  low /= nlow;
  mu->bass = mu->bass * 0.5f + low * 0.5f;

  mu->since_beat += seconds;
  mu->beat = 0;
  if (mu->bass > mu->bass_avg * 1.25f && mu->bass > 0.18f
      && mu->since_beat > 0.28f) {
    mu->beat = 1;
    mu->since_beat = 0;
    mu->beat_glow = 1;
  }
  mu->bass_avg = mu->bass_avg * 0.96f + mu->bass * 0.04f;
  mu->beat_glow -= seconds * 2.5f;
  if (mu->beat_glow < 0) mu->beat_glow = 0;
}

/* ---------------------------------------------------------------------- */
/* Looks                                                                   */
/* ---------------------------------------------------------------------- */

int look_texture(const char * name)
{
  border_def_t def;
  int tex = texture_get(name);
  if (tex < 0) {
    tex = texture_dup(texture_get("bordertile"), name);
  }
  if (tex >= 0) {
    border_get_def(def, 1);
    border_customize(tex, def);
  }
  return tex;
}

void look_new_border(int tex)
{
  border_def_t def;
  if (tex <= 0) return;
  border_get_def(def, (unsigned short) rand());
  border_customize(tex, def);
}

void look_hsv(vtx_t * c, float h, float s, float v, float a)
{
  float f, p, q, t, r, g, b;
  int i;
  h = h - (float)(int) h;
  if (h < 0) h += 1;
  h *= 6;
  i = (int) h;
  f = h - i;
  p = v * (1 - s);
  q = v * (1 - s * f);
  t = v * (1 - s * (1 - f));
  switch (i) {
  case 0: r = v; g = t; b = p; break;
  case 1: r = q; g = v; b = p; break;
  case 2: r = p; g = v; b = t; break;
  case 3: r = p; g = q; b = v; break;
  case 4: r = t; g = p; b = v; break;
  default: r = v; g = p; b = q; break;
  }
  /* vtx_t colours are x:r y:g z:b w:a in DrawObject */
  c->x = r; c->y = g; c->z = b; c->w = a;
}

void cam_view(matrix_t v, float x, float y, float z, float yaw, float pitch)
{
  MtxIdentity(v);
  MtxTranslate(v, -x, -y, -z);
  MtxRotateY(v, -yaw);
  MtxRotateX(v, -pitch);
}

void cam_local(matrix_t local, matrix_t model, matrix_t view)
{
  MtxMult3(local, model, view);
}

float fclamp(float v, float lo, float hi)
{
  return v < lo ? lo : (v > hi ? hi : v);
}

float frand(void)
{
  return (rand() & 0xFFFF) * (1.0f / 65536.0f);
}

/* ---------------------------------------------------------------------- */
/* Base                                                                    */
/* ---------------------------------------------------------------------- */

float base_process(base_t * b, viewport_t * vp, matrix_t proj, int ms)
{
  float s;
  if (!b->ready) return 0;
  b->vp = *vp;
  MtxCopy(b->proj, proj);
  s = ms * (1.0f / 1000.0f);
  if (s > 0.1f) s = 0.1f; /* after a pause, do not jump */
  if (s <= 0) s = 0.001f;
  b->t += s;
  music_update(&b->mu, s);
  if (b->mu.beat) ++b->beats;
  return s;
}

obj_driver_t * base_object(const char * name)
{
  return (obj_driver_t *) driver_list_search(&obj_drivers, name);
}

void base_release(obj_driver_t ** o)
{
  if (*o) {
    driver_dereference(&(*o)->common);
    *o = 0;
  }
}

/* ---------------------------------------------------------------------- */
/* The plugin : its first driver                                           */
/* ---------------------------------------------------------------------- */

any_driver_t * lef_main(void)
{
  return (any_driver_t *) &tunnel_driver;
}
