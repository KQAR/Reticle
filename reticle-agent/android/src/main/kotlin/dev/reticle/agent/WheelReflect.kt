package dev.reticle.agent

import android.view.View
import dev.reticle.core.MetadataValue

/**
 * What a THIRD-PARTY wheel column publishes about itself.
 *
 * `wheel:opaque` was written on the belief that a self-drawn wheel exposes nothing:
 * it paints every value onto its own canvas, owns no child view in the hierarchy,
 * and publishes no accessibility node, so from the tree it is byte-for-byte a plain
 * empty `View`. That is true of the *tree*. It turned out not to be true of the
 * *widget*: measured against the wheel the original report was actually about — the
 * `WheelView` family that most Android date/region pickers use — the column's own
 * class publishes its position, its item count and its item text through ordinary
 * PUBLIC methods:
 *
 *  - `getCurrentItem(): int` — the selected position;
 *  - `getViewAdapter()` / `getAdapter()` — the item source, with `getItemsCount(): int`;
 *  - `getItemText(int): CharSequence` (the text-adapter contract) or `getItem(int)`
 *    where that returns the VALUE rather than a recycled row view.
 *
 * So the caller who measured a row pitch off a screenshot and calibrated a swipe by
 * trial was reverse-engineering from pixels what the control had a getter for. That
 * is the same finding that closed the `NumberPicker` half, one library over.
 *
 * ## What keeps this a reading rather than a guess
 *
 * The accessors are matched by NAME, which is the part that could go wrong, so every
 * step is checked rather than trusted:
 *
 *  - only nodes already in the wheel FAMILY are probed at all (see
 *    `SnapshotCapture.suspectedWheel`), so an unrelated class with a `getCurrentItem`
 *    is never asked;
 *  - every result is type-checked, and a position outside `0..count-1` is discarded
 *    rather than published — a wheel whose two accessors disagree is not a wheel this
 *    can read;
 *  - a `getItem(int)` that answers with a `View` is a row RECYCLER, not a label
 *    source, and is refused by return type (that is exactly what the `WheelView`
 *    family's adapter does);
 *  - an object label is only accepted when it can be turned into text by a contract
 *    (`CharSequence`, a number, a `getPickerViewText()`, or an overridden
 *    `toString()`); `com.example.Foo@1a2b` is not a wheel value;
 *  - a wheel whose VALUE cannot be read publishes nothing here and stays
 *    `wheel:opaque`. Half a reading — a position with no label — would let
 *    `act wheel --to "1995"` look supported on a column that cannot say what it
 *    landed on;
 *  - `wheelSource` records which accessors answered, so any reading here can be
 *    audited from `ui node` instead of being taken on faith.
 *
 * The row pitch is the one value with no public getter in either family (a private
 * method in one, a package-private field in the other). It is read the same way
 * `NumberPicker`'s is — reflectively, type-checked, and labelled `estimated` when it
 * falls back to `height / visibleItems` — because a swipe distance is arithmetic
 * either way and the re-read after each swipe is what makes the result true.
 */
internal object WheelReflect {

    /** Positions, in preference order. All public no-arg getters in the wild families. */
    private val INDEX_METHODS = listOf(
        "getCurrentItem",
        "getSelectedItemPosition",
        "getSelectedItem",
        "getCurrentPosition",
    )

    /** The item source. */
    private val ADAPTER_METHODS = listOf("getViewAdapter", "getAdapter", "getWheelAdapter")

    /** Item counts, on the adapter. */
    private val COUNT_METHODS = listOf("getItemsCount", "getItemCount", "getCount")

    /** Row pitch, on the wheel itself. */
    private val PITCH_METHODS = listOf("getItemHeight", "getItemHeightPx")

    /** Row pitch, as a field, when there is no method for it. */
    private val PITCH_FIELDS = listOf("itemHeight", "mItemHeight", "rowHeight", "mRowHeight")

    /** How many rows the column shows at once — only used to estimate a pitch. */
    private val VISIBLE_METHODS = listOf("getVisibleItems", "getItemsVisible")
    private val VISIBLE_FIELDS = listOf("itemsVisible", "mItemsVisible", "visibleItems")

    /**
     * The wheel's own state, or an empty map when this column cannot be read — in
     * which case it keeps saying `wheel:opaque`, which is then the truth about it.
     *
     * [itemsCap] bounds both the published label list and the number of adapter
     * lookups made: a year wheel has 120 items and a region wheel thousands, and a
     * capture must not walk all of them.
     */
    fun facts(view: View, itemsCap: Int): Map<String, MetadataValue> {
        val position = firstInt(view, INDEX_METHODS) ?: return emptyMap()
        val (index, indexMethod) = position
        val adapter = ADAPTER_METHODS.firstNotNullOfOrNull { name ->
            noArg(view, name)?.let { it to name }
        } ?: return emptyMap()
        val (source, adapterMethod) = adapter
        val count = firstInt(source, COUNT_METHODS)?.first ?: return emptyMap()
        // Two accessors that disagree are not a wheel this can read. Published, the
        // pair would make `act wheel` aim at a position the widget does not have.
        if (count <= 0 || index < 0 || index >= count) return emptyMap()

        val labels = ArrayList<String>(minOf(count, itemsCap))
        var labelMethod: String? = null
        for (i in 0 until minOf(count, itemsCap)) {
            val (text, via) = labelAt(source, i) ?: break
            labels.add(text)
            labelMethod = via
        }
        // The SELECTED value has to be readable whether or not it is inside the
        // capped window: a wheel sitting on item 300 is exactly the case a caller
        // needs the label for.
        val value = labels.getOrNull(index) ?: labelAt(source, index)
            ?.also { labelMethod = labelMethod ?: it.second }
            ?.first
            ?: return emptyMap()

        val out = LinkedHashMap<String, MetadataValue>()
        out["wheelIndex"] = MetadataValue.Integer(index.toLong())
        out["wheelMin"] = MetadataValue.Integer(0L)
        out["wheelMax"] = MetadataValue.Integer((count - 1).toLong())
        out["wheelValue"] = MetadataValue.Text(value)
        if (labels.isNotEmpty()) {
            out["wheelItems"] = MetadataValue.Text(labels.joinToString(","))
            if (count > labels.size) {
                out["wheelItemsTruncated"] = MetadataValue.Integer((count - labels.size).toLong())
            }
        }
        val pitch = pitch(view)
        if (pitch != null) {
            out["wheelRowHeightPx"] = MetadataValue.Integer(pitch.value.toLong())
            if (!pitch.measured) out["wheelRowHeightEstimated"] = MetadataValue.Bool(true)
        }
        // The audit trail for a name-matched reading: which getters answered, on which
        // class. Without it a value here would have to be taken on faith.
        out["wheelSource"] = MetadataValue.Text(
            buildString {
                append("reflect:")
                append(view.javaClass.simpleName)
                append(".")
                append(indexMethod)
                append("/")
                append(adapterMethod)
                labelMethod?.let { append(".").append(it) }
                pitch?.let { append("/").append(it.via) }
            }
        )
        return out
    }

    /** The first of [names] that answers with an `int`, and which one it was. */
    private fun firstInt(target: Any, names: List<String>): Pair<Int, String>? =
        names.firstNotNullOfOrNull { name ->
            (noArg(target, name) as? Int)?.let { it to name }
        }

    /** One item's label and the accessor that produced it, or null. */
    private fun labelAt(adapter: Any, index: Int): Pair<String, String>? {
        textOf(invokeInt(adapter, "getItemText", index))?.let { return it to "getItemText" }
        // `getItem(int)` is the value in one family and a recycled ROW VIEW in the
        // other; the second is refused by what it answers with, not by name.
        textOf(invokeInt(adapter, "getItem", index))?.let { return it to "getItem" }
        return null
    }

    /**
     * Text for a wheel item, or null when the object cannot be turned into a label by
     * any contract. A `View` is a recycled row rather than a value, and a class that
     * never overrode `toString` would contribute `com.example.Foo@1a2b`.
     */
    private fun textOf(value: Any?): String? {
        if (value == null || value is View) return null
        val text = when {
            value is CharSequence -> value.toString()
            value is Number -> value.toString()
            else -> {
                val picker = noArg(value, "getPickerViewText") as? CharSequence
                picker?.toString() ?: value.takeIf { hasOwnToString(it) }?.toString()
            }
        }
        return text?.trim()?.takeIf { it.isNotEmpty() }
    }

    private fun hasOwnToString(value: Any): Boolean = runCatching {
        value.javaClass.getMethod("toString").declaringClass != Any::class.java
    }.getOrDefault(false)

    private fun invokeInt(target: Any, name: String, argument: Int): Any? = runCatching {
        val method = ReticleReflect.cachedMethod(target, "$name(int)") { cls ->
            method(cls) {
                it.name == name && it.parameterTypes.size == 1 &&
                    (it.parameterTypes[0] == Int::class.javaPrimitiveType ||
                        it.parameterTypes[0] == Integer::class.java)
            }
        } ?: return null
        // Refused by RETURN TYPE as well as by result: a `getItem` declared to answer
        // with a row view must not be called at all — building a view during a
        // read-only capture is a side effect, whatever it returns.
        if (View::class.java.isAssignableFrom(method.returnType)) return null
        method.invoke(target, argument)
    }.getOrNull()

    /**
     * Call a no-arg method by name, whatever its visibility and whatever the
     * visibility of the class declaring it.
     *
     * Not `ReticleReflect.invokeNoArg`, which resolves through `Class.getMethods()`:
     * an adapter is very often an anonymous or package-private class, and a public
     * method on a non-public class cannot be invoked reflectively without being made
     * accessible first. That failure would be silent and would look exactly like the
     * widget publishing nothing — the confusion this whole file exists to remove.
     */
    private fun noArg(target: Any, name: String): Any? = runCatching {
        val method = ReticleReflect.cachedMethod(target, "wheel:$name()") { cls ->
            method(cls) { it.name == name && it.parameterTypes.isEmpty() }
        } ?: return null
        method.invoke(target)
    }.getOrNull()

    /**
     * The first method matching [predicate], searched over the class's public API and
     * then declaration by declaration up the chain (which is what reaches a private
     * `getItemHeight()`), made accessible before it is handed back.
     */
    private fun method(
        cls: Class<*>,
        predicate: (java.lang.reflect.Method) -> Boolean,
    ): java.lang.reflect.Method? {
        cls.methods.firstOrNull(predicate)?.let { return it.apply { isAccessible = true } }
        var current: Class<*>? = cls
        while (current != null) {
            current.declaredMethods.firstOrNull(predicate)?.let { return it.apply { isAccessible = true } }
            current = current.superclass
        }
        return null
    }

    /** A pitch reading, and whether it was READ or derived from the visible-row count. */
    private data class Pitch(val value: Int, val measured: Boolean, val via: String)

    private fun pitch(view: View): Pitch? {
        for (name in PITCH_METHODS) {
            val value = numberFrom(noArg(view, name))?.toInt()?.takeIf { it > 0 } ?: continue
            return Pitch(value, measured = true, via = name)
        }
        for (name in PITCH_FIELDS) {
            val value = numberFrom(fieldValue(view, name))?.toInt()?.takeIf { it > 0 } ?: continue
            return Pitch(value, measured = true, via = name)
        }
        // Last resort, and labelled as such: a wheel of N visible rows has a pitch of
        // height/N. Wrong by a row on a widget that draws partial rows at the edges,
        // which costs `act wheel` an extra swipe rather than a wrong answer.
        val visible = VISIBLE_METHODS.firstNotNullOfOrNull { numberFrom(noArg(view, it))?.toInt() }
            ?: VISIBLE_FIELDS.firstNotNullOfOrNull { numberFrom(fieldValue(view, it))?.toInt() }
        if (visible != null && visible > 0 && view.height >= visible) {
            return Pitch(view.height / visible, measured = false, via = "height/visibleItems")
        }
        return null
    }

    private fun fieldValue(target: Any, name: String): Any? = runCatching {
        var current: Class<*>? = target.javaClass
        while (current != null) {
            val field = current.declaredFields.firstOrNull { it.name == name }
            if (field != null) {
                field.isAccessible = true
                return field.get(target)
            }
            current = current.superclass
        }
        null
    }.getOrNull()

    private fun numberFrom(value: Any?): Number? = value as? Number
}
