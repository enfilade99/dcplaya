#include <math.h>

static float force2(float v)
{
  return 0.2f;
}

static float force(float v)
{
  float w = 0;
  
  v += 0.1;

  w += cos(v);
  w += sin(v);
  w += cos(v);
  w += sin(v);
  w += tan(v);
  w += cosh(v);
  w += sinh(v);
  w += tanh(v);
  w += atan(v);
  w += atan2(v,v);
  w += sqrt(v);
  w += pow(v,v);
  w += acos(v);
  w += exp(v); 
  w += hypot(v,v);
  w += ldexp(v,2);
  w += log(v);

  return w;
}

int force_math(float v)
{
  return force(v) + force2(v);
}

/* DC99 rebuild: plugins are linked against the main program at load time, so
 * every compiler helper (libgcc) a plugin may call has to be present here.
 * Modern gcc no longer happens to pull these in by itself. */
#define G(x) extern void x(void);
#define DC99_LIBGCC \
  G(__moddi3) G(__divdi3) G(__udivdi3) G(__umoddi3) G(__muldi3) \
  G(__ashldi3) G(__ashrdi3) G(__lshrdi3) G(__negdi2) G(__cmpdi2) G(__ucmpdi2) \
  G(__fixunssfsi) G(__fixunsdfsi) G(__fixsfdi) G(__fixdfdi) G(__fixunssfdi) G(__fixunsdfdi) \
  G(__floatdisf) G(__floatdidf) G(__floatundisf) G(__floatundidf) \
  G(__sdivsi3_i4) G(__udivsi3_i4) G(__sdivsi3) G(__udivsi3) G(__sdivsi3_i4i) G(__udivsi3_i4i) \
  G(__movmem) G(__movmem_i4_even) G(__movmem_i4_odd) G(__movmemSI12_i4) \
  G(__ashlsi3) G(__ashrsi3) G(__lshrsi3) G(__ashiftrt_r4_0) G(__mulsi3) \
  G(__clzsi2) G(__clzdi2) G(__ctzsi2) G(__ffsdi2) G(__popcountsi2) G(__bswapsi2) G(__bswapdi2) \
  G(__adddf3) G(__subdf3) G(__muldf3) G(__divdf3) G(__extendsfdf2) G(__truncdfsf2) \
  G(__fixdfsi) G(__floatsidf) G(__floatunsidf) G(__eqdf2) G(__nedf2) G(__gtdf2) G(__gedf2) G(__ltdf2) G(__ledf2) G(__unorddf2) G(__unordsf2)
DC99_LIBGCC
#undef G
#define G(x) (void *) x,
void * const dc99_force_libgcc[] = { DC99_LIBGCC 0 };
