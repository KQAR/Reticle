package dev.reticle.sample

import android.os.Bundle
import android.view.Gravity
import android.widget.LinearLayout
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import dev.reticle.agent.Reticle

/**
 * Home screen for the sample app. Each row opens one focused Reticle scenario so
 * the report stays readable instead of mixing every probe target on one screen.
 */
class MainActivity : AppCompatActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.TOP
            setPadding(48, 48, 48, 48)
        }

        root.addView(TextView(this).apply {
            text = "Reticle Sample Scenarios"
            textSize = 22f
            tag = "home.title"
        })
        SampleScenario.entries.forEach { scenario ->
            root.addView(scenarioRow(scenario))
        }
        setContentView(root)

        // App-authored evidence via the log / view-metadata bridge.
        Reticle.log("home_visible", mapOf("scenarioCount" to SampleScenario.entries.size))
    }

    private fun scenarioRow(scenario: SampleScenario): TextView =
        TextView(this).apply {
            text = "${scenario.title}\n${scenario.subtitle}"
            textSize = 18f
            tag = scenario.testId
            isClickable = true
            isFocusable = true
            setPadding(0, 28, 0, 28)
            setOnClickListener {
                Reticle.log("scenario_opened", mapOf("scenario" to scenario.testId))
                startActivity(scenario.intent(this@MainActivity))
            }
        }
}
