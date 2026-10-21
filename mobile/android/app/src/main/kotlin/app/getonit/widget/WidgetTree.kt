package app.getonit.widget

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.GlanceTheme
import androidx.glance.action.Action
import androidx.glance.action.ActionParameters
import androidx.glance.action.actionParametersOf
import androidx.glance.appwidget.action.actionStartActivity
import androidx.glance.action.clickable
import androidx.glance.appwidget.LinearProgressIndicator
import androidx.glance.appwidget.action.ActionCallback
import androidx.glance.appwidget.action.actionRunCallback
import androidx.glance.appwidget.components.Scaffold
import androidx.glance.appwidget.cornerRadius
import androidx.glance.background
import androidx.glance.layout.Alignment
import androidx.glance.layout.Box
import androidx.glance.layout.Column
import androidx.glance.layout.Row
import androidx.glance.layout.Spacer
import androidx.glance.layout.fillMaxWidth
import androidx.glance.layout.height
import androidx.glance.layout.padding
import androidx.glance.layout.size
import androidx.glance.layout.width
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextStyle
import androidx.glance.unit.ColorProvider
import es.antonborri.home_widget.HomeWidgetBackgroundIntent
import org.json.JSONArray
import org.json.JSONObject

/**
 * Draws a plain widget tree made by the Flutter side (spec §10.3). The tree
 * has no bindings: Flutter filled them in. Unknown components draw nothing.
 */
object WidgetTree {
    /** Actions that only write data run in the background; the rest open the app. */
    private val dataActions = setOf("mark_done", "toggle_done", "log_progress")

    val jsonKey = ActionParameters.Key<String>("json")

    fun action(ctx: Context, action: JSONObject?): Action? {
        action ?: return null
        val json = action.toString()
        return if (action.optString("type") in dataActions) {
            actionRunCallback<DataActionCallback>(actionParametersOf(jsonKey to json))
        } else {
            actionStartActivity(
                Intent(Intent.ACTION_VIEW, Uri.parse("getonit://action?json=" + Uri.encode(json)))
                    .setComponent(ComponentName(ctx.packageName, "app.getonit.MainActivity"))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
            )
        }
    }

    fun parseColor(hex: String?): Color? =
        if (hex != null && Regex("^#[0-9a-fA-F]{6}$").matches(hex)) Color(android.graphics.Color.parseColor(hex)) else null

    fun JSONArray?.nodes(): List<JSONObject> =
        if (this == null) emptyList() else (0 until length()).mapNotNull { optJSONObject(it) }
}

/** Sends a data action to the Dart background callback (home_widget). */
class DataActionCallback : ActionCallback {
    override suspend fun onAction(context: Context, glanceId: GlanceId, parameters: ActionParameters) {
        val json = parameters[WidgetTree.jsonKey] ?: return
        HomeWidgetBackgroundIntent.getBroadcast(context, Uri.parse("getonit://widget?json=" + Uri.encode(json))).send()
    }
}

@Composable
fun RenderNode(ctx: Context, node: JSONObject, accent: Color?) {
    val a = WidgetTree.parseColor(node.optString("accent", "").ifEmpty { null }) ?: accent
    val primary = a?.let { ColorProvider(it) } ?: GlanceTheme.colors.primary
    val onSurface = GlanceTheme.colors.onSurface
    val muted = GlanceTheme.colors.onSurfaceVariant
    val click = WidgetTree.action(ctx, node.optJSONObject("action"))
    fun GlanceModifier.onClick(): GlanceModifier = if (click != null) clickable(click) else this

    when (node.optString("type")) {
        "column" -> Column(modifier = GlanceModifier.fillMaxWidth()) {
            val gap = node.optDouble("gap", 0.0).dp
            node.optJSONArray("children").let { with(WidgetTree) { it.nodes() } }.forEachIndexed { i, c ->
                if (i > 0 && gap > 0.dp) Spacer(GlanceModifier.height(gap))
                RenderNode(ctx, c, a)
            }
        }
        "row", "grid" -> {
            val children = with(WidgetTree) { node.optJSONArray("children").nodes() }
            val between = node.optString("align") == "between" || node.optString("type") == "grid"
            Row(modifier = GlanceModifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                val gap = node.optDouble("gap", 0.0).dp
                children.forEachIndexed { i, c ->
                    if (i > 0 && gap > 0.dp) Spacer(GlanceModifier.width(gap))
                    if (c.optBoolean("expand") || node.optString("type") == "grid") {
                        Box(modifier = GlanceModifier.defaultWeight()) { RenderNode(ctx, c, a) }
                    } else {
                        RenderNode(ctx, c, a)
                    }
                    if (between && i == 0 && children.size > 1 && !c.optBoolean("expand") && node.optString("type") != "grid") {
                        Spacer(GlanceModifier.defaultWeight())
                    }
                }
            }
        }
        "card" -> Box(
            modifier = GlanceModifier.fillMaxWidth()
                .background(a?.let { ColorProvider(it.copy(alpha = 0.16f)) } ?: GlanceTheme.colors.secondaryContainer)
                .cornerRadius(16.dp)
                .padding(if (node.optString("style") == "tile") 10.dp else 12.dp)
                .onClick(),
        ) { node.optJSONObject("child")?.let { RenderNode(ctx, it, a) } }
        "text" -> {
            val style = node.optString("style", "body")
            var value = node.optString("value")
            if (style == "label") value = value.uppercase()
            Text(
                value,
                maxLines = node.optInt("maxLines", if (style == "caption") 2 else 3),
                style = when (style) {
                    "display" -> TextStyle(fontSize = 22.sp, fontWeight = FontWeight.Bold, color = onSurface)
                    "title" -> TextStyle(fontSize = 16.sp, fontWeight = FontWeight.Bold, color = onSurface)
                    "subtitle" -> TextStyle(fontSize = 15.sp, fontWeight = FontWeight.Medium, color = onSurface)
                    "caption" -> TextStyle(fontSize = 12.sp, color = muted)
                    "label" -> TextStyle(fontSize = 11.sp, fontWeight = FontWeight.Bold, color = primary)
                    else -> TextStyle(fontSize = 14.sp, color = onSurface)
                },
            )
        }
        "icon" -> Text(node.optString("name"), style = TextStyle(fontSize = 20.sp))
        "badge" -> Text(
            node.optString("label"),
            modifier = GlanceModifier.background(GlanceTheme.colors.surfaceVariant).cornerRadius(10.dp).padding(horizontal = 8.dp, vertical = 2.dp),
            style = TextStyle(fontSize = 12.sp, fontWeight = FontWeight.Medium, color = when (node.optString("tone")) {
                "success" -> ColorProvider(Color(0xFF2E7D4F))
                "warning" -> ColorProvider(Color(0xFFB26A00))
                "danger" -> GlanceTheme.colors.error
                else -> muted
            }),
        )
        "stat" -> Column {
            Text(node.optString("value"), style = TextStyle(fontSize = 15.sp, fontWeight = FontWeight.Bold, color = onSurface))
            Text(node.optString("label"), style = TextStyle(fontSize = 11.sp, color = muted))
        }
        "progress_bar" -> LinearProgressIndicator(
            progress = node.optDouble("value", 0.0).toFloat().coerceIn(0f, 1f),
            modifier = GlanceModifier.fillMaxWidth().height(6.dp),
            color = primary,
            backgroundColor = GlanceTheme.colors.surfaceVariant,
        )
        // Glance has no determinate ring; a label over a short bar says the same.
        "progress_ring" -> Column(horizontalAlignment = Alignment.CenterHorizontally) {
            val label = node.optString("label")
            if (label.isNotEmpty()) Text(label, style = TextStyle(fontSize = 14.sp, fontWeight = FontWeight.Bold, color = onSurface))
            val sub = node.optString("sublabel")
            if (sub.isNotEmpty()) Text(sub, style = TextStyle(fontSize = 10.sp, color = muted))
            LinearProgressIndicator(
                progress = node.optDouble("value", 0.0).toFloat().coerceIn(0f, 1f),
                modifier = GlanceModifier.width(node.optDouble("size", 56.0).dp).height(5.dp),
                color = primary,
                backgroundColor = GlanceTheme.colors.surfaceVariant,
            )
        }
        "media" -> {
            val w = node.optDouble("width", 48.0).dp
            val h = node.optDouble("height", 48.0).dp
            if (node.optString("kind") == "pdf_page") {
                Box(
                    modifier = GlanceModifier.size(w, h).background(ColorProvider(Color(0xFFF5F1E8))).cornerRadius(8.dp).padding(4.dp),
                    contentAlignment = Alignment.BottomEnd,
                ) { Text(node.optString("page"), style = TextStyle(fontSize = 10.sp, color = ColorProvider(Color(0xFF6B6455)))) }
            } else {
                Box(
                    modifier = GlanceModifier.size(w, h).background(ColorProvider(Color(0xFF8C1515))).cornerRadius(8.dp),
                    contentAlignment = Alignment.Center,
                ) { Text("▶", style = TextStyle(fontSize = 18.sp, color = ColorProvider(Color.White))) }
            }
        }
        "button" -> {
            val label = node.optString("label")
            Text(
                label,
                modifier = GlanceModifier.background(a?.let { ColorProvider(it.copy(alpha = 0.28f)) } ?: GlanceTheme.colors.secondaryContainer)
                    .cornerRadius(18.dp).padding(horizontal = 14.dp, vertical = 8.dp).onClick(),
                style = TextStyle(fontSize = 14.sp, fontWeight = FontWeight.Medium, color = onSurface),
            )
        }
        "checklist_item" -> Row(
            modifier = GlanceModifier.fillMaxWidth().padding(vertical = 4.dp).onClick(),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(if (node.optBoolean("checked")) "☑" else "☐", style = TextStyle(fontSize = 18.sp, color = primary))
            Spacer(GlanceModifier.width(8.dp))
            Column(modifier = GlanceModifier.defaultWeight()) {
                Text(node.optString("label"), maxLines = 2, style = TextStyle(fontSize = 14.sp, color = onSurface))
                val sub = node.optString("sublabel")
                if (sub.isNotEmpty()) Text(sub, maxLines = 1, style = TextStyle(fontSize = 11.sp, color = muted))
            }
        }
        "counter" -> Row(verticalAlignment = Alignment.CenterVertically) {
            for ((label, key) in listOf("−" to "decrement", "+" to "increment")) {
                val act = WidgetTree.action(ctx, node.optJSONObject(key))
                Box(
                    modifier = GlanceModifier.size(36.dp).background(GlanceTheme.colors.secondaryContainer).cornerRadius(18.dp)
                        .let { if (act != null) it.clickable(act) else it },
                    contentAlignment = Alignment.Center,
                ) { Text(label, style = TextStyle(fontSize = 18.sp, color = onSurface)) }
                if (key == "decrement") Spacer(GlanceModifier.width(6.dp))
            }
        }
        "week_dots" -> Row(modifier = GlanceModifier.fillMaxWidth()) {
            with(WidgetTree) { node.optJSONArray("days").nodes() }.forEach { d ->
                Box(modifier = GlanceModifier.defaultWeight(), contentAlignment = Alignment.Center) {
                    Box(
                        modifier = GlanceModifier.size(14.dp).cornerRadius(7.dp).background(
                            when (d.optString("s")) {
                                "done" -> primary
                                "rest" -> ColorProvider(Color.Transparent)
                                else -> GlanceTheme.colors.surfaceVariant
                            },
                        ),
                    ) {}
                }
            }
        }
        "divider" -> Spacer(GlanceModifier.fillMaxWidth().height(1.dp).background(GlanceTheme.colors.outline))
        "spacer" -> Spacer(GlanceModifier.size(node.optDouble("size", 8.0).dp))
        else -> {}
    }
}

/** The frame every widget draws its tree in. */
@Composable
fun WidgetFrame(ctx: Context, tree: JSONObject?, empty: String) {
    GlanceTheme {
        Scaffold(backgroundColor = GlanceTheme.colors.widgetBackground, horizontalPadding = 12.dp) {
            Column(modifier = GlanceModifier.fillMaxWidth().padding(vertical = 12.dp)) {
                if (tree == null) {
                    Text(empty, style = TextStyle(fontSize = 14.sp, color = GlanceTheme.colors.onSurface))
                } else {
                    RenderNode(ctx, tree, null)
                }
            }
        }
    }
}
