package app.getonit.widget

import android.content.Context
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.dp
import androidx.glance.appwidget.testing.unit.runGlanceAppWidgetUnitTest
import androidx.glance.testing.unit.assertHasClickAction
import androidx.glance.testing.unit.hasText
import androidx.test.core.app.ApplicationProvider
import org.json.JSONObject
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class WidgetTreeTest {
    private val context: Context = ApplicationProvider.getApplicationContext()

    /** A resolved tile_wide of the course template, as Flutter sends it. */
    private val courseTile = JSONObject(
        """
        {"type":"card","accent":"#e0573f",
         "action":{"type":"open_goal","params":{"goalId":"cs229"}},
         "child":{"type":"column","gap":12,"children":[
           {"type":"row","gap":12,"children":[
             {"type":"progress_ring","value":0.42,"size":56,"label":"42%"},
             {"type":"column","expand":true,"children":[
               {"type":"text","style":"subtitle","value":"Stanford CS229: Machine Learning","maxLines":1},
               {"type":"text","style":"caption","value":"Next: Lecture 8: Kernels"}]},
             {"type":"badge","label":"✓ Today","tone":"success"}]},
           {"type":"button","variant":"tonal","label":"▶ Resume 34:12",
            "action":{"type":"open_video","params":{"videoId":"abc","goalId":"cs229","itemId":"lec-08"}}}]}}
        """.trimIndent(),
    )

    @Test fun drawsTheTextOfAResolvedTile() = runGlanceAppWidgetUnitTest {
        setAppWidgetSize(DpSize(320.dp, 160.dp))
        setContext(context)
        provideComposable { RenderNode(context, courseTile, null) }
        onNode(hasText("Stanford CS229: Machine Learning")).assertExists()
        onNode(hasText("Next: Lecture 8: Kernels")).assertExists()
        onNode(hasText("42%")).assertExists()
        onNode(hasText("✓ Today")).assertExists()
        onNode(hasText("▶ Resume 34:12")).assertHasClickAction()
    }

    @Test fun habitTileWithCounterAndChecklist() = runGlanceAppWidgetUnitTest {
        setContext(context)
        val tree = JSONObject(
            """
            {"type":"column","children":[
              {"type":"row","children":[
                {"type":"icon","name":"💧"},
                {"type":"text","value":"Drink water"},
                {"type":"counter",
                 "decrement":{"type":"log_progress","params":{"goalId":"water","delta":-1}},
                 "increment":{"type":"log_progress","params":{"goalId":"water","delta":1}}}]},
              {"type":"checklist_item","label":"Stretch","checked":true,
               "action":{"type":"toggle_done","params":{"goalId":"m","stepId":"s"}}},
              {"type":"checklist_item","label":"Journal","checked":false},
              {"type":"hologram"}]}
            """.trimIndent(),
        )
        provideComposable { RenderNode(context, tree, null) }
        onNode(hasText("Drink water")).assertExists()
        onNode(hasText("+")).assertExists()
        onNode(hasText("−")).assertExists()
        onNode(hasText("☑")).assertExists()
        onNode(hasText("☐")).assertExists()
        onNode(hasText("Stretch")).assertExists()
    }

    /**
     * Small and medium widgets of AI-made plans (Claude's answers to the
     * in-app prompts), resolved by Flutter. test/ai_tiles_test.dart writes the
     * file and keeps it current.
     */
    @Test fun drawsTheTextOfAiMadeWidgets() {
        val text = javaClass.classLoader!!.getResource("ai_tiles.json").readText()
        val cases = org.json.JSONArray(text)
        org.junit.Assert.assertTrue(cases.length() >= 8)
        for (i in 0 until cases.length()) {
            val case = cases.getJSONObject(i)
            val tree = case.getJSONObject("tree")
            val texts = case.getJSONArray("texts")
            val wide = case.getString("name").endsWith(":tile_wide")
            runGlanceAppWidgetUnitTest {
                setAppWidgetSize(if (wide) DpSize(320.dp, 160.dp) else DpSize(160.dp, 160.dp))
                setContext(context)
                provideComposable { RenderNode(context, tree, null) }
                for (j in 0 until texts.length()) {
                    // "Practice" is also part of "Spanish practice": any match will do.
                    val shown = hasText(texts.getString(j), ignoreCase = true)
                    onAllNodes(shown).assertAny(shown)
                }
            }
        }
    }

    @Test fun dataActionsRunInTheBackgroundAndOthersOpenTheApp() {
        val data = WidgetTree.action(context, JSONObject("{\"type\":\"mark_done\",\"params\":{\"goalId\":\"g\"}}"))
        val open = WidgetTree.action(context, JSONObject("{\"type\":\"open_goal\",\"params\":{\"goalId\":\"g\"}}"))
        org.junit.Assert.assertTrue(data!!.javaClass.name, data.javaClass.name.contains("RunCallback"))
        org.junit.Assert.assertTrue(open!!.javaClass.name, open.javaClass.name.contains("StartActivity"))
        org.junit.Assert.assertNull(WidgetTree.action(context, null))
    }
}
