package dev.reticle.sample

import android.graphics.Color
import android.graphics.drawable.ColorDrawable
import android.os.Bundle
import android.view.Gravity
import android.view.View
import android.widget.ArrayAdapter
import android.widget.Button
import android.widget.LinearLayout
import android.widget.PopupMenu
import android.widget.PopupWindow
import android.widget.Spinner
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import dev.reticle.agent.Reticle

/**
 * The app-owned windows that are NOT dialogs. `AlertDialog` is already covered,
 * but each of these attaches its own root to `WindowManagerGlobal` through a
 * different framework path, and a harness that only handles dialogs can miss
 * them:
 *
 *  - `PopupWindow` — an app-authored floating window (tooltips, custom menus);
 *  - a `Spinner`'s dropdown — a framework popup whose rows are the only way to
 *    pick a value;
 *  - `PopupMenu` — the overflow menu shape, rendered in its own popup window.
 *
 * Every one carries an observable side effect so a tap that resolves inside the
 * popup can be told apart from one that hit the screen behind it.
 */
class PopupScenarioActivity : AppCompatActivity() {

    private lateinit var status: TextView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        status = TextView(this).apply {
            text = "Idle"
            textSize = 20f
            tag = "popup.status"
        }

        val popupTrigger = Button(this).apply {
            text = "Show popup window"
            tag = "popup.trigger"
            setOnClickListener { showPopupWindow(it) }
        }

        val spinner = Spinner(this).apply {
            tag = "popup.spinner"
            adapter = ArrayAdapter(
                this@PopupScenarioActivity,
                android.R.layout.simple_spinner_dropdown_item,
                SPINNER_ITEMS,
            )
            setSelection(0)
            setOnItemSelectedListener(object : android.widget.AdapterView.OnItemSelectedListener {
                override fun onItemSelected(parent: android.widget.AdapterView<*>?, view: View?, position: Int, id: Long) {
                    if (position == 0) return
                    status.text = "Spinner: ${SPINNER_ITEMS[position]}"
                    Reticle.log("popup_spinner_picked", mapOf("value" to SPINNER_ITEMS[position]))
                }

                override fun onNothingSelected(parent: android.widget.AdapterView<*>?) = Unit
            })
        }

        val menuTrigger = Button(this).apply {
            text = "Show overflow menu"
            tag = "popup.menuTrigger"
            setOnClickListener { anchor -> showOverflowMenu(anchor) }
        }

        setContentView(
            LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                gravity = Gravity.CENTER
                setPadding(48, 48, 48, 48)
                addView(status)
                addView(popupTrigger)
                addView(spinner)
                addView(menuTrigger)
            }
        )
        Reticle.log("popup_visible", mapOf("windows" to "popupWindow+spinner+popupMenu"))
    }

    private fun showPopupWindow(anchor: View) {
        val content = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Color.WHITE)
            setPadding(32, 32, 32, 32)
            addView(TextView(this@PopupScenarioActivity).apply {
                text = "Popup content"
                tag = "popupWindow.title"
                textSize = 18f
            })
            addView(TextView(this@PopupScenarioActivity).apply {
                text = "Apply filter"
                tag = "popupWindow.action"
                textSize = 18f
                isClickable = true
                setPadding(0, 24, 0, 24)
            })
        }
        val popup = PopupWindow(
            content,
            LinearLayout.LayoutParams.WRAP_CONTENT,
            LinearLayout.LayoutParams.WRAP_CONTENT,
            true,
        ).apply {
            setBackgroundDrawable(ColorDrawable(Color.WHITE))
            elevation = 24f
            showAsDropDown(anchor, 0, 24)
        }
        content.findViewWithTag<TextView>("popupWindow.action").setOnClickListener {
            status.text = "Popup applied"
            Reticle.log("popup_window_applied", emptyMap())
            popup.dismiss()
        }
        Reticle.log("popup_window_opened", emptyMap())
    }

    private fun showOverflowMenu(anchor: View) {
        PopupMenu(this, anchor).apply {
            menu.add("Rename")
            menu.add("Delete item")
            setOnMenuItemClickListener { item ->
                status.text = "Menu: ${item.title}"
                Reticle.log("popup_menu_picked", mapOf("item" to item.title.toString()))
                true
            }
            show()
        }
        Reticle.log("popup_menu_opened", emptyMap())
    }

    private companion object {
        val SPINNER_ITEMS = listOf("Choose a plan", "Basic", "Pro")
    }
}
