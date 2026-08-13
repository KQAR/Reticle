package dev.reticle.agent

import android.content.Context
import android.view.View
import dev.reticle.core.MetadataValue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Reading a third-party wheel column through the accessors its own class publishes.
 *
 * The point of every case here is the same one: the reading is matched by NAME, so the
 * failure mode to guard is not "a wheel goes unread" but "something that is not a
 * wheel reading gets published as one". Each shape below is a stand-in for a family
 * seen in the wild — the recycler adapter that answers `getItem` with a row VIEW, the
 * value adapter that answers with the value, the column whose accessors disagree — and
 * the assertion is what Reticle refuses to say about it.
 */
@RunWith(RobolectricTestRunner::class)
class WheelReflectTest {

    private val context: Context = RuntimeEnvironment.getApplication()

    /** The text-adapter contract: `getItemText(int)` answering with a CharSequence. */
    private class TextAdapter(private val items: List<String>) {
        fun getItemsCount(): Int = items.size
        fun getItemText(index: Int): CharSequence = items[index]
    }

    /** The shape of the family whose adapter builds RECYCLED ROW VIEWS. */
    private class RecyclerAdapter(private val context: Context, private val items: List<String>) {
        fun getItemsCount(): Int = items.size
        fun getItem(index: Int): View = android.widget.TextView(context).apply { text = items[index] }
    }

    /** The other family: `getItem(int)` IS the value. */
    private class ValueAdapter(private val items: List<String>) {
        fun getItemsCount(): Int = items.size
        fun getItem(index: Int): Any = items[index]
    }

    private open class WheelViewStub(context: Context) : View(context) {
        var position = 0
        var source: Any? = null
        fun getCurrentItem(): Int = position
        fun getViewAdapter(): Any? = source
    }

    private fun facts(view: View, cap: Int = 40): Map<String, MetadataValue> =
        WheelReflect.facts(view, cap)

    @Test
    fun `reads position, range, labels and value off the wheel's own getters`() {
        val wheel = WheelViewStub(context).apply {
            source = TextAdapter(listOf("1993", "1994", "1995"))
            position = 2
        }
        val out = facts(wheel)
        assertEquals(MetadataValue.Integer(2), out["wheelIndex"])
        assertEquals(MetadataValue.Integer(0), out["wheelMin"])
        assertEquals(MetadataValue.Integer(2), out["wheelMax"])
        assertEquals(MetadataValue.Text("1995"), out["wheelValue"])
        assertEquals(MetadataValue.Text("1993,1994,1995"), out["wheelItems"])
    }

    /** The audit trail. A name-matched reading that cannot be traced is one taken on faith. */
    @Test
    fun `names the accessors that answered`() {
        val wheel = WheelViewStub(context).apply {
            source = TextAdapter(listOf("a", "b"))
            position = 0
        }
        val source = (facts(wheel)["wheelSource"] as MetadataValue.Text).value
        assertTrue(source.startsWith("reflect:WheelViewStub."), source)
        assertTrue(source.contains("getCurrentItem"), source)
        assertTrue(source.contains("getViewAdapter.getItemText"), source)
    }

    /**
     * The case that would have poisoned the whole feature: one family's `getItem(int)`
     * inflates a row view. Called, it mutates during a read-only capture; published, it
     * turns `android.widget.TextView{...}` into a wheel value.
     */
    @Test
    fun `refuses an adapter whose getItem answers with a row view`() {
        val wheel = WheelViewStub(context).apply {
            source = RecyclerAdapter(context, listOf("1993", "1994"))
            position = 1
        }
        assertTrue(facts(wheel).isEmpty(), "a recycler adapter publishes no readable label")
    }

    @Test
    fun `reads the family whose getItem is the value itself`() {
        val wheel = WheelViewStub(context).apply {
            source = ValueAdapter(listOf("PL", "DE"))
            position = 1
        }
        val out = facts(wheel)
        assertEquals(MetadataValue.Text("DE"), out["wheelValue"])
        assertTrue((out["wheelSource"] as MetadataValue.Text).value.endsWith(".getItem"))
    }

    /** Two accessors that disagree are not a wheel this can read. */
    @Test
    fun `refuses a position outside the item count`() {
        val wheel = WheelViewStub(context).apply {
            source = TextAdapter(listOf("a", "b"))
            position = 7
        }
        assertTrue(facts(wheel).isEmpty())
    }

    @Test
    fun `publishes nothing for a column with no adapter at all`() {
        val wheel = WheelViewStub(context).apply { position = 3 }
        assertTrue(facts(wheel).isEmpty(), "this is the genuinely opaque wheel")
    }

    /**
     * An object label is only accepted through a contract. `com.example.Foo@1a2b` is
     * not a wheel value, and publishing it would read as one.
     */
    @Test
    fun `refuses a label that is only an object identity`() {
        class Opaque
        class OpaqueAdapter {
            fun getItemsCount(): Int = 2
            fun getItem(index: Int): Any = Opaque()
        }
        val wheel = WheelViewStub(context).apply {
            source = OpaqueAdapter()
            position = 0
        }
        assertTrue(facts(wheel).isEmpty())
    }

    /** The `IPickerViewData`-style contract one family uses for non-string items. */
    @Test
    fun `takes a label from an item that publishes its own picker text`() {
        class Item(private val text: String) {
            fun getPickerViewText(): CharSequence = text
        }
        class ItemAdapter {
            fun getItemsCount(): Int = 1
            fun getItem(index: Int): Any = Item("Mazowieckie")
        }
        val wheel = WheelViewStub(context).apply {
            source = ItemAdapter()
            position = 0
        }
        assertEquals(MetadataValue.Text("Mazowieckie"), facts(wheel)["wheelValue"])
    }

    /**
     * The label list is capped and the shortfall is exact, so a truncated list never
     * reads as the whole wheel — and the SELECTED value is readable even when it sits
     * outside the capped window, which is the case a caller actually needs.
     */
    @Test
    fun `caps the label list, counts the remainder, and still names a value beyond the cap`() {
        val wheel = WheelViewStub(context).apply {
            source = TextAdapter((1900..1999).map(Int::toString))
            position = 95
        }
        val out = facts(wheel, cap = 12)
        assertEquals(12, (out["wheelItems"] as MetadataValue.Text).value.split(',').size)
        assertEquals(MetadataValue.Integer(88), out["wheelItemsTruncated"])
        assertEquals(MetadataValue.Text("1995"), out["wheelValue"])
    }

    /** A pitch with no public getter is still read, and a derived one says so. */
    @Test
    fun `reads a row pitch through a private accessor`() {
        class PitchedWheelView(context: Context) : WheelViewStub(context) {
            private fun getItemHeight(): Int = 157
        }
        val wheel = PitchedWheelView(context).apply {
            source = TextAdapter(listOf("a", "b"))
            position = 0
        }
        val out = facts(wheel)
        assertEquals(MetadataValue.Integer(157), out["wheelRowHeightPx"])
        assertNull(out["wheelRowHeightEstimated"])
    }

    @Test
    fun `marks a pitch derived from the visible-row count as estimated`() {
        class VisibleWheelView(context: Context) : WheelViewStub(context) {
            fun getVisibleItems(): Int = 5
        }
        val wheel = VisibleWheelView(context).apply {
            source = TextAdapter(listOf("a", "b"))
            position = 0
            layout(0, 0, 200, 600)
        }
        val out = facts(wheel)
        assertEquals(MetadataValue.Integer(120), out["wheelRowHeightPx"])
        assertEquals(MetadataValue.Bool(true), out["wheelRowHeightEstimated"])
    }
}
