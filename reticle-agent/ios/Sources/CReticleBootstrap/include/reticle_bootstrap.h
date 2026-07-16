#ifndef RETICLE_BOOTSTRAP_H
#define RETICLE_BOOTSTRAP_H

// The bootstrap logic is a load-time constructor in reticle_bootstrap.c. The
// anchor below exists only so ReticleInjection can reference it and stop the
// linker from dead-stripping the constructor's translation unit.
void reticle_bootstrap_anchor(void);

#endif /* RETICLE_BOOTSTRAP_H */
