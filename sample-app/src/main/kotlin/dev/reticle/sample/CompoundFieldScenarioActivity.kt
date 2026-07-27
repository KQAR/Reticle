package dev.reticle.sample

import android.os.Bundle
import android.view.Gravity
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import dev.reticle.agent.Reticle

/**
 * The compound input widget — where the only unique handle is NOT the thing that
 * takes text.
 *
 * Real forms are built from a reusable row: an outer container carries the stable,
 * unique id, and the `EditText` nested inside it reuses one generic id on every row
 * of the page. So the container is the only selector that identifies a field, and
 * targeting it is what the docs steer you toward — but a tap on it moves no focus,
 * because it is clickable, not focusable-in-touch-mode. `adb input text` then goes
 * to whatever held focus before, which is usually nothing at all: `act type`
 * reported `chars=4` and the field stayed empty.
 *
 * Two things this scenario is built to expose, both of which `type` now checks:
 *   - the wrapper is `tappable` but NOT focusable, and the tree says so
 *     (`isFocusable` is the touch reading — under API 26+ `FOCUSABLE_AUTO` a plain
 *     clickable container claims `isFocusable = true`, which is the false positive
 *     that makes this shape look fine);
 *   - the wrapper holds exactly ONE focusable input, so a retarget is not a guess.
 *
 * The third row is the case where it IS a guess: two inputs under one wrapper, so
 * `type` must refuse and name the problem rather than pick one.
 */
class CompoundFieldScenarioActivity : AppCompatActivity() {

    private lateinit var status: TextView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        status = TextView(this).apply {
            text = "Idle"
            textSize = 18f
            tag = "compound.status"
        }

        val first = compoundRow(label = "First name", wrapperTag = "compound.firstName")
        val last = compoundRow(label = "Last name", wrapperTag = "compound.lastName")
        val ambiguous = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            tag = "compound.ambiguous"
            // Clickable, like the rows above — the shape that reads as targetable.
            setOnClickListener { Reticle.log("compound_wrapper_tapped", mapOf("wrapper" to "compound.ambiguous")) }
            addView(rowLabel("Date of birth"))
            addView(genericInput(hint = "MM"))
            addView(genericInput(hint = "YYYY"))
        }

        val submit = Button(this).apply {
            text = "Submit"
            tag = "compound.submit"
            setOnClickListener {
                val values = listOf(first, last)
                    .mapNotNull { row -> (row.getChildAt(1) as? EditText)?.text?.toString() }
                status.text = "Submitted: ${values.joinToString(" / ")}"
                Reticle.log("compound_submitted", mapOf("values" to values.joinToString("/")))
            }
        }

        setContentView(
            LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                gravity = Gravity.TOP
                setPadding(48, 48, 48, 48)
                addView(status)
                addView(first)
                addView(last)
                addView(ambiguous)
                addView(submit)
            }
        )
    }

    /** A form row: unique id on the wrapper, generic id on the input inside it. */
    private fun compoundRow(label: String, wrapperTag: String): LinearLayout =
        LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            tag = wrapperTag
            // A click listener makes the row `tappable` — and, on API 26+, makes
            // `isFocusable` report true under FOCUSABLE_AUTO while a tap still
            // focuses nothing. That gap is the whole scenario.
            setOnClickListener { Reticle.log("compound_wrapper_tapped", mapOf("wrapper" to wrapperTag)) }
            addView(rowLabel(label))
            addView(genericInput(hint = label))
        }

    /**
     * A deliberately TALL label, so the wrapper's centre — where a selector-resolved
     * tap lands — falls on the label and not on the input below it. That is what
     * makes this scenario reproduce the reported failure instead of accidentally
     * hitting the field: with a short label the centre lands inside the `EditText`
     * and focus arrives by luck.
     */
    private fun rowLabel(text: String): TextView =
        TextView(this).apply {
            this.text = text
            minHeight = 320
            gravity = Gravity.TOP
        }

    /** The repeated inner field: the same tag on every row, so it is no handle at all. */
    private fun genericInput(hint: String): EditText =
        EditText(this).apply {
            this.hint = hint
            // Deliberately NOT unique: this is what a reusable row component does.
            tag = "compound.input"
        }
}
