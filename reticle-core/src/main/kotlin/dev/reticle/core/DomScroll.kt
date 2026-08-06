package dev.reticle.core

/**
 * A DOM scroll port's numbers turned into the same [ScrollInfo] a native
 * container publishes — the twin of `ReticleProtocol.DomScroll`.
 *
 * Web content used to publish no scroll capability at all: `overflow` sat in the
 * style channel and nothing said whether a pane could still move, so a form
 * whose submit button was one flick below the fold looked identical to one that
 * had none. Inside an iframe it was worse, since the frame scrolls its OWN
 * document — the host page's `scrollY` says nothing about it, and `scroll-to`
 * had no container to drive.
 *
 * The derivation lives here rather than in either bridge because both agents
 * emit it and the compact projection reads it; a rule spelled twice is a rule
 * that drifts.
 */
object DomScroll {

    /**
     * Sub-pixel layout makes `scrollHeight` exceed `clientHeight` by fractions on
     * pages that cannot scroll at all, so a bare `>` reported `scroll:down` on
     * half the nodes of an ordinary page. One pixel of slack is the smallest
     * threshold that keeps that noise out while a real scroll port — which is
     * always at least a row taller — still registers.
     */
    private const val SLACK = 1.0

    /**
     * null when this element has no scroll port (the traversal reports -1 for
     * every metric), or when it has one that cannot move in any direction — the
     * same rule a native container follows: [ScrollInfo] is present only where
     * there is a capability to report.
     */
    fun fromMetrics(
        scrollLeft: Double,
        scrollTop: Double,
        scrollWidth: Double,
        scrollHeight: Double,
        clientWidth: Double,
        clientHeight: Double,
    ): ScrollInfo? {
        if (scrollWidth < 0 || scrollHeight < 0 || clientWidth < 0 || clientHeight < 0) return null
        val info = ScrollInfo(
            canScrollUp = scrollTop > SLACK,
            canScrollDown = scrollTop + clientHeight < scrollHeight - SLACK,
            canScrollLeft = scrollLeft > SLACK,
            canScrollRight = scrollLeft + clientWidth < scrollWidth - SLACK,
        )
        return if (info.isScrollable) info else null
    }
}
