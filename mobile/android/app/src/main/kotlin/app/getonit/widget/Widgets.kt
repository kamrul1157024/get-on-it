package app.getonit.widget

import android.app.Activity
import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.os.Bundle
import android.widget.ArrayAdapter
import android.widget.ListView
import android.widget.TextView
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.dp
import androidx.glance.GlanceId
import androidx.glance.LocalSize
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetManager
import androidx.glance.appwidget.SizeMode
import androidx.glance.appwidget.provideContent
import androidx.glance.currentState
import es.antonborri.home_widget.HomeWidgetGlanceState
import es.antonborri.home_widget.HomeWidgetGlanceStateDefinition
import es.antonborri.home_widget.HomeWidgetGlanceWidgetReceiver
import es.antonborri.home_widget.HomeWidgetPlugin
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject

private fun SharedPreferences.tree(key: String): JSONObject? =
    getString(key, null)?.let { runCatching { JSONObject(it) }.getOrNull() }

/** Today's goals in one widget: open goals first (spec §10.5, auto_today). */
class TodayWidget : GlanceAppWidget() {
    override val stateDefinition = HomeWidgetGlanceStateDefinition()
    override val sizeMode = SizeMode.Exact

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        provideContent {
            val prefs = currentState<HomeWidgetGlanceState>().preferences
            WidgetFrame(context, prefs.tree("today"), "Open Get On It once to set up this widget.")
        }
    }
}

/** One goal, chosen when the widget is added. Small and medium layouts. */
class GoalWidget : GlanceAppWidget() {
    override val stateDefinition = HomeWidgetGlanceStateDefinition()
    override val sizeMode = SizeMode.Responsive(setOf(SMALL, MEDIUM))

    companion object {
        val SMALL = DpSize(120.dp, 120.dp)
        val MEDIUM = DpSize(250.dp, 120.dp)

        fun goalKey(appWidgetId: Int) = "widget.$appWidgetId"
    }

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val appWidgetId = GlanceAppWidgetManager(context).getAppWidgetId(id)
        provideContent {
            val prefs = currentState<HomeWidgetGlanceState>().preferences
            val goalId = prefs.getString(goalKey(appWidgetId), null)
                ?: prefs.getString("goals", null)?.let { JSONArray(it).optJSONObject(0)?.optString("id") }
            val size = if (LocalSize.current.width < MEDIUM.width) "small" else "medium"
            WidgetFrame(context, goalId?.let { prefs.tree("goal:$it:$size") }, "Add a goal in Get On It first.")
        }
    }
}

class TodayWidgetReceiver : HomeWidgetGlanceWidgetReceiver<TodayWidget>() {
    override val glanceAppWidget = TodayWidget()
}

class GoalWidgetReceiver : HomeWidgetGlanceWidgetReceiver<GoalWidget>() {
    override val glanceAppWidget = GoalWidget()
}

/** Asks which goal a new Goal widget shows. */
class GoalWidgetConfigActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val appWidgetId = intent?.extras?.getInt(AppWidgetManager.EXTRA_APPWIDGET_ID, AppWidgetManager.INVALID_APPWIDGET_ID)
            ?: AppWidgetManager.INVALID_APPWIDGET_ID
        setResult(RESULT_CANCELED, Intent().putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, appWidgetId))
        if (appWidgetId == AppWidgetManager.INVALID_APPWIDGET_ID) return finish()

        val prefs = HomeWidgetPlugin.getData(this)
        val goals = JSONArray(prefs.getString("goals", "[]"))
        val items = (0 until goals.length()).map { goals.getJSONObject(it) }
        if (items.isEmpty()) {
            setContentView(TextView(this).apply {
                text = "Open Get On It and add a goal first."
                setPadding(48, 48, 48, 48)
            })
            return
        }
        setTitle("Choose a goal")
        val list = ListView(this)
        list.adapter = ArrayAdapter(this, android.R.layout.simple_list_item_1, items.map { "${it.optString("icon")}  ${it.optString("title")}" })
        list.setOnItemClickListener { _, _, position, _ ->
            prefs.edit().putString(GoalWidget.goalKey(appWidgetId), items[position].getString("id")).apply()
            val context = applicationContext
            CoroutineScope(Dispatchers.Default).launch {
                val glanceId = GlanceAppWidgetManager(context).getGlanceIdBy(appWidgetId)
                GoalWidget().update(context, glanceId)
            }
            setResult(RESULT_OK, Intent().putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, appWidgetId))
            finish()
        }
        setContentView(list)
    }
}
