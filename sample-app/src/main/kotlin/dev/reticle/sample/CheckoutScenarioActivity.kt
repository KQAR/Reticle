package dev.reticle.sample

import android.os.Bundle
import android.view.Gravity
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import dev.reticle.agent.Reticle

/** Basic native controls used to prove selector actions and runtime mutation. */
class CheckoutScenarioActivity : AppCompatActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setPadding(48, 48, 48, 48)
        }

        val status = TextView(this).apply {
            text = "Cart: 3 items"
            textSize = 20f
            tag = "checkout.status"
        }

        val payButton = Button(this).apply {
            text = "Pay now"
            tag = "checkout.payButton"
            setOnClickListener {
                status.text = "Paid!"
                Reticle.log("checkout_paid", mapOf("itemCount" to 3, "method" to "card"))
            }
        }

        // Exercises both ASCII input and the non-ASCII clipboard+paste path.
        val nameField = EditText(this).apply {
            tag = "checkout.nameField"
            hint = "Name on card"
        }

        root.addView(status)
        root.addView(payButton)
        root.addView(nameField)
        setContentView(root)

        Reticle.attachMetadata("checkout.payButton", mapOf("screen" to "checkout", "variant" to "primary"))
        Reticle.log("checkout_visible", mapOf("cartId" to "cart-123", "itemCount" to 3))
    }
}
