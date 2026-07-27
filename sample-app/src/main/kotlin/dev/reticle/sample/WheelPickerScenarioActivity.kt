package dev.reticle.sample

import android.os.Bundle
import android.view.Gravity
import android.widget.Button
import android.widget.LinearLayout
import android.widget.NumberPicker
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import dev.reticle.agent.Reticle

/**
 * The wheel picker — a control whose *candidate* values are not addressable, only
 * its current one.
 *
 * `NumberPicker` in spinner mode draws the neighbouring values itself on the
 * wheel canvas; the only child view it owns is the `EditText` holding the
 * selection. So the tree can report "the wheel is at 09" but there is no node for
 * "10" to tap — reaching another value is a drag along the wheel, and the
 * evidence that it worked is the wheel's own text changing. That is a different
 * shape from every other picker already covered here: a `Spinner` dropdown
 * (`scenario.popups`) materialises real row nodes in a popup window, and a
 * recycling list (`scenario.list`) binds a row once scrolled. A wheel never
 * materialises anything.
 *
 * Two wheels sit side by side on purpose: they are the same widget class with the
 * same internal child ids, so picking one requires the app-supplied testId and a
 * selector that resolves by type alone is ambiguous.
 */
class WheelPickerScenarioActivity : AppCompatActivity() {

    private lateinit var status: TextView
    private lateinit var hourPicker: NumberPicker
    private lateinit var minutePicker: NumberPicker

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        status = TextView(this).apply {
            text = "Idle"
            textSize = 20f
            tag = "wheel.status"
        }

        hourPicker = NumberPicker(this).apply {
            tag = "wheel.hour"
            minValue = 0
            maxValue = HOURS.lastIndex
            displayedValues = HOURS
            value = HOURS.indexOf("09")
            wrapSelectorWheel = true
            setOnValueChangedListener { _, _, new ->
                Reticle.log("wheel_hour_changed", mapOf("value" to HOURS[new]))
            }
        }

        minutePicker = NumberPicker(this).apply {
            tag = "wheel.minute"
            minValue = 0
            maxValue = MINUTES.lastIndex
            displayedValues = MINUTES
            value = 0
            wrapSelectorWheel = true
            setOnValueChangedListener { _, _, new ->
                Reticle.log("wheel_minute_changed", mapOf("value" to MINUTES[new]))
            }
        }

        // A THIRD column that is not a NumberPicker at all: a self-drawn wheel, the
        // shape most third-party date pickers use. It publishes nothing — no child,
        // no adapter, no accessibility surface — so it is where `wheel:opaque` has
        // to carry the whole message.
        val yearWheel = SelfDrawnWheelView(this).apply {
            tag = "wheel.year"
            values = YEARS
            onValueChanged = { value ->
                Reticle.log("wheel_year_changed", mapOf("value" to value))
            }
        }

        val wheels = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            addView(yearWheel)
            addView(hourPicker)
            addView(TextView(this@WheelPickerScenarioActivity).apply {
                text = ":"
                textSize = 24f
                setPadding(24, 0, 24, 0)
                tag = "wheel.separator"
            })
            addView(minutePicker)
        }

        val confirm = Button(this).apply {
            text = "Confirm time"
            tag = "wheel.confirm"
            setOnClickListener {
                val picked = "${HOURS[hourPicker.value]}:${MINUTES[minutePicker.value]}"
                status.text = "Time: $picked"
                Reticle.log("wheel_confirmed", mapOf("time" to picked))
            }
        }

        setContentView(
            LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                gravity = Gravity.CENTER
                setPadding(48, 48, 48, 48)
                addView(status)
                addView(wheels)
                addView(confirm)
            }
        )

        Reticle.log(
            "wheel_visible",
            mapOf("hour" to HOURS[hourPicker.value], "minute" to MINUTES[minutePicker.value]),
        )
    }

    private companion object {
        val HOURS = Array(24) { "%02d".format(it) }
        val MINUTES = arrayOf("00", "15", "30", "45")
        val YEARS = List(40) { (1980 + it).toString() }
    }
}

/**
 * A wheel that owns everything: it paints its values onto its own canvas, handles
 * its own drags, and exposes no child view, no adapter and no accessibility node.
 *
 * This is the shape a third-party date/region picker actually has, and it is the
 * hard case for an observer: from outside it is byte-for-byte a plain empty
 * `View`. Reticle marks it `wheel:opaque` from the widget family — the honest
 * "screenshots and swipes are the only way in", rather than the silence that used
 * to read as a decorative rectangle.
 */
class SelfDrawnWheelView(context: android.content.Context) : android.view.View(context) {

    var values: List<String> = emptyList()
    var onValueChanged: ((String) -> Unit)? = null

    /** The value at the centre of the wheel — readable by the app, never by the tree. */
    val selected: String? get() = values.getOrNull(index)

    private var index = 0
    private var dragStartY = 0f
    private var dragStartIndex = 0
    private val paint = android.graphics.Paint(android.graphics.Paint.ANTI_ALIAS_FLAG).apply {
        textAlign = android.graphics.Paint.Align.CENTER
        textSize = 44f
    }

    /** Row pitch in pixels: the constant a caller otherwise measures off a screenshot. */
    private val rowHeight = 120f

    override fun onMeasure(widthSpec: Int, heightSpec: Int) {
        setMeasuredDimension(resolveSize(300, widthSpec), resolveSize((rowHeight * 5).toInt(), heightSpec))
    }

    override fun onDraw(canvas: android.graphics.Canvas) {
        val centre = height / 2f
        for (offset in -2..2) {
            val value = values.getOrNull(index + offset) ?: continue
            paint.alpha = if (offset == 0) 255 else 90
            canvas.drawText(value, width / 2f, centre + offset * rowHeight + paint.textSize / 3f, paint)
        }
    }

    override fun onTouchEvent(event: android.view.MotionEvent): Boolean {
        when (event.actionMasked) {
            android.view.MotionEvent.ACTION_DOWN -> {
                dragStartY = event.y
                dragStartIndex = index
                return true
            }
            android.view.MotionEvent.ACTION_MOVE, android.view.MotionEvent.ACTION_UP -> {
                val steps = ((dragStartY - event.y) / rowHeight).toInt()
                val next = (dragStartIndex + steps).coerceIn(0, (values.size - 1).coerceAtLeast(0))
                if (next != index) {
                    index = next
                    invalidate()
                    selected?.let { onValueChanged?.invoke(it) }
                }
                return true
            }
        }
        return super.onTouchEvent(event)
    }
}
