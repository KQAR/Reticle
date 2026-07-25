package dev.reticle.sample

import android.os.Bundle
import android.view.Gravity
import android.view.ViewGroup
import android.widget.LinearLayout
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import dev.reticle.agent.Reticle

/**
 * A long recycling list — the shape every real E2E flow hits ("tap the 40th
 * row") and the one case where a selector is not merely off-viewport but ABSENT:
 * a `RecyclerView` only keeps the visible window (plus a small prefetch) bound,
 * so `list.item40` has no View, no semantics node, and no frame until it is
 * scrolled into range.
 *
 * The status row stays pinned above the list so a tap on a far-down row has an
 * observable effect that doesn't itself require scrolling to read.
 */
class ListScenarioActivity : AppCompatActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val status = TextView(this).apply {
            text = "No row picked"
            textSize = 20f
            tag = "list.status"
        }

        val list = RecyclerView(this).apply {
            tag = "list.rows"
            layoutManager = LinearLayoutManager(this@ListScenarioActivity)
            adapter = RowAdapter(ROW_COUNT) { index ->
                status.text = "Picked row $index"
                Reticle.log("list_row_picked", mapOf("index" to index))
            }
        }

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(24, 24, 24, 0)
            addView(status)
            addView(
                list,
                LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    0,
                ).apply { weight = 1f },
            )
        }
        setContentView(root)

        Reticle.log("list_visible", mapOf("rows" to ROW_COUNT))
    }

    private class RowAdapter(
        private val count: Int,
        private val onPick: (Int) -> Unit,
    ) : RecyclerView.Adapter<RowAdapter.RowHolder>() {

        class RowHolder(val label: TextView) : RecyclerView.ViewHolder(label)

        override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): RowHolder {
            val label = TextView(parent.context).apply {
                textSize = 18f
                gravity = Gravity.CENTER_VERTICAL
                minHeight = ROW_HEIGHT
                isClickable = true
            }
            return RowHolder(label)
        }

        override fun onBindViewHolder(holder: RowHolder, position: Int) {
            holder.label.text = "Row $position"
            // The testId travels with the DATA, not the recycled holder, so a
            // rebound holder always reports the row it currently shows.
            holder.label.tag = "list.item$position"
            holder.label.setOnClickListener { onPick(position) }
        }

        override fun getItemCount(): Int = count
    }

    private companion object {
        const val ROW_COUNT = 60
        const val ROW_HEIGHT = 160
    }
}
