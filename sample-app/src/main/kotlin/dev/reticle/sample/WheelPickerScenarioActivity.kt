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

        val wheels = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
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
    }
}
