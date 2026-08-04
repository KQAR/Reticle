package dev.reticle.sample

import android.os.Bundle
import android.os.SystemClock
import android.text.Editable
import android.text.InputFilter
import android.text.TextWatcher
import android.view.Gravity
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import dev.reticle.agent.Reticle

/**
 * The field that answers a `type` with FEWER characters than it was given.
 *
 * `act type` reported `chars=5` for `--text "10000"` and the field held `100`;
 * the adjacent field on the same screen took the same five characters intact. The
 * difference was what each field does per keystroke: the lossy one reformats its
 * value in a `TextWatcher` and drives a re-render of a widget above it — 101
 * changes in the action trace against the other's 6 — and `adb shell input text`
 * delivers the string as a burst of key events that such a field can lose out of
 * the middle of.
 *
 * Two rows, one property each, because the two readings must not be conflated:
 *
 *  - `reformat.amount` **adds** to what it is given (thousands separators). Every
 *    character arrived; the app dressed the value. `type` reports
 *    `textLanded=reformatted` and leaves it alone — an app formatting its own
 *    input is not a defect, and re-typing over it would fight the app.
 *  - `reformat.lossy` **loses** part of a burst. `type` reports the shortfall and
 *    re-sends the text over the clipboard, which a `TextWatcher` sees as one
 *    change rather than a run of keystrokes.
 *
 * The loss here is deterministic rather than a real race: the watcher drops an
 * insertion that arrives within [BURST_WINDOW_MS] of the previous one. A fixture
 * that reproduced the timing race honestly would reproduce it only sometimes, and
 * a flaky fixture is worth less than no fixture — what is being pinned is
 * Reticle's reading of the outcome, not the app's ability to lose a keystroke.
 * The re-layout that causes the real thing is here too (the bound summary above
 * the field rebuilds its rows on every change), so the trace has the shape the
 * report described.
 */
class ReformattingFieldScenarioActivity : AppCompatActivity() {

    private lateinit var summary: LinearLayout
    private lateinit var status: TextView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        status = TextView(this).apply {
            text = "Idle"
            textSize = 18f
            tag = "reformat.status"
        }
        // The bound widget the report described: it redraws on every keystroke,
        // which is what makes the burst expensive enough to lose characters.
        summary = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            tag = "reformat.summary"
        }
        renderSummary("")

        val amount = field(tag = "reformat.amount", hint = "Amount")
        amount.addTextChangedListener(GroupingWatcher(amount))

        val lossy = field(tag = "reformat.lossy", hint = "Amount (bursty)")
        lossy.addTextChangedListener(BurstDroppingWatcher(lossy) { renderSummary(it) })

        // The third reading, and the one a screenshot used to be the only way to
        // get: a field PREFILLED to its own `maxLength`. Its text looks exactly
        // like a hint showing through an empty field, and a `type` into it lands
        // nothing — which used to be reported as a bare `textLanded=none`, i.e.
        // indistinguishable from a tool failure.
        val full = field(tag = "reformat.capped", hint = "Phone")
        full.filters = arrayOf(InputFilter.LengthFilter(FULL_FIELD_LIMIT))
        full.setText("880 977 267")

        setContentView(
            LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                gravity = Gravity.TOP
                setPadding(48, 48, 48, 48)
                addView(status)
                addView(summary)
                addView(rowLabel("Formats what it is given"))
                addView(amount)
                addView(rowLabel("Loses part of a burst"))
                addView(lossy)
                addView(rowLabel("Already at its maxLength"))
                addView(full)
            }
        )
    }

    /** Rebuild the bound rows above the field — a real layout pass per keystroke. */
    private fun renderSummary(value: String) {
        summary.removeAllViews()
        repeat(SUMMARY_ROWS) { i ->
            summary.addView(
                TextView(this).apply {
                    text = if (i == 0) "Entered: ${value.ifEmpty { "—" }}" else "row $i"
                    tag = if (i == 0) "reformat.bound" else null
                }
            )
        }
        status.text = if (value.isEmpty()) "Idle" else "Entered: $value"
        Reticle.log("reformat_changed", mapOf("value" to value))
    }

    private fun field(tag: String, hint: String): EditText =
        EditText(this).apply {
            this.hint = hint
            this.tag = tag
        }

    private fun rowLabel(text: String): TextView =
        TextView(this).apply { this.text = text }

    /** Inserts thousands separators: everything typed is kept, plus punctuation. */
    private class GroupingWatcher(private val field: EditText) : TextWatcher {
        private var editing = false

        override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) = Unit
        override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) = Unit

        override fun afterTextChanged(s: Editable?) {
            if (editing) return
            val digits = s?.toString()?.filter { it.isDigit() } ?: return
            val grouped = digits.reversed().chunked(3).joinToString(",").reversed()
            if (grouped == s.toString()) return
            editing = true
            field.setText(grouped)
            field.setSelection(grouped.length)
            editing = false
        }
    }

    /**
     * Drops a single-character insertion that arrives on the heels of the previous
     * one, and rebuilds the bound summary on every accepted change.
     *
     * Two conditions, both load-bearing, because what is being modelled is a burst
     * of *keystrokes* and nothing else:
     *
     *  - one character at a time. A clipboard paste arrives as one change carrying
     *    the whole string, which is exactly why `type` re-sends that way — a
     *    `TextWatcher` cannot cut it in half;
     *  - close behind another insertion. A deletion resets the run, so the
     *    recovery path's `KEYCODE_DEL` clear can never make the paste that follows
     *    it look like the tail of a burst.
     */
    private class BurstDroppingWatcher(
        private val field: EditText,
        private val onAccepted: (String) -> Unit,
    ) : TextWatcher {
        private var editing = false
        private var accepted = ""
        private var lastAcceptedAt = 0L
        private var inRun = false

        override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) = Unit
        override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) = Unit

        override fun afterTextChanged(s: Editable?) {
            if (editing) return
            val incoming = s?.toString() ?: return
            if (incoming == accepted) return
            val now = SystemClock.uptimeMillis()
            val isKeystroke = incoming.length == accepted.length + 1
            if (isKeystroke && inRun && now - lastAcceptedAt < BURST_WINDOW_MS) {
                editing = true
                field.setText(accepted)
                field.setSelection(accepted.length)
                editing = false
                return
            }
            inRun = incoming.length > accepted.length
            accepted = incoming
            lastAcceptedAt = now
            onAccepted(incoming)
        }
    }

    private companion object {
        /** An insertion closer than this to the previous one is dropped. */
        const val BURST_WINDOW_MS = 120L

        /** Enough bound rows that each keystroke costs a real layout pass. */
        const val SUMMARY_ROWS = 12

        /** The capped row's limit, and the length of the value it starts full with. */
        const val FULL_FIELD_LIMIT = 11
    }
}
