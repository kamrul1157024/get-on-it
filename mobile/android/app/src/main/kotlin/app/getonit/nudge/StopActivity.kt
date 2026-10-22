package app.getonit.nudge

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.Typeface
import android.net.Uri
import android.os.Bundle
import android.os.CountDownTimer
import android.view.Gravity
import android.view.ViewGroup.LayoutParams.MATCH_PARENT
import android.view.ViewGroup.LayoutParams.WRAP_CONTENT
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import android.window.OnBackInvokedDispatcher
import app.getonit.MainActivity

/**
 * Push me hard: covers a watched app past its limit. It shows the lost time,
 * what it could have been, and the next task. "Do it now" opens the work;
 * "Back to <app>" unlocks after a 10-second countdown. Plain views, so it
 * opens fast without the Flutter engine.
 */
class StopActivity : Activity() {
    companion object {
        private const val WAIT_MS = 10_000L

        fun intent(ctx: Context, n: Nudge): Intent = Intent(ctx, StopActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_NO_HISTORY or Intent.FLAG_ACTIVITY_EXCLUDE_FROM_RECENTS)
            .putExtra("title", n.title)
            .putExtra("body", n.body)
            .putExtra("work", "${n.work.title} · ${n.work.body}")
            .putExtra("link", n.work.link)
            .putExtra("app", n.app?.label ?: "the app")
    }

    private var timer: CountDownTimer? = null
    private var canLeave = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val dp = resources.displayMetrics.density
        fun text(s: String?, size: Float, bold: Boolean = false, alpha: Float = 1f) = TextView(this).apply {
            text = s
            textSize = size
            setTextColor(Color.WHITE)
            this.alpha = alpha
            gravity = Gravity.CENTER
            if (bold) setTypeface(typeface, Typeface.BOLD)
            setPadding(0, (8 * dp).toInt(), 0, (8 * dp).toInt())
        }
        val app = intent.getStringExtra("app")
        val doIt = Button(this).apply {
            text = "Do it now"
            setOnClickListener {
                startActivity(
                    Intent(Intent.ACTION_VIEW, Uri.parse(intent.getStringExtra("link")), this@StopActivity, MainActivity::class.java)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
                )
                finish()
            }
        }
        val back = Button(this).apply {
            isEnabled = false
            setOnClickListener { finish() }
        }
        setContentView(
            LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                gravity = Gravity.CENTER
                setBackgroundColor(Color.rgb(28, 16, 48))
                setPadding((32 * dp).toInt(), 0, (32 * dp).toInt(), 0)
                addView(text("Stop.", 40f, bold = true))
                addView(text(intent.getStringExtra("title"), 22f, bold = true))
                addView(text(intent.getStringExtra("body"), 17f))
                addView(text("Next: ${intent.getStringExtra("work")}", 15f, alpha = 0.8f))
                addView(doIt, LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT).apply { topMargin = (32 * dp).toInt() })
                addView(back, LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT).apply { topMargin = (8 * dp).toInt() })
            },
        )
        timer = object : CountDownTimer(WAIT_MS, 1000) {
            override fun onTick(left: Long) {
                back.text = "Back to $app in ${(left + 999) / 1000} s"
            }

            override fun onFinish() {
                canLeave = true
                back.isEnabled = true
                back.text = "Back to $app"
            }
        }.start()
        // The back gesture waits for the countdown too.
        if (android.os.Build.VERSION.SDK_INT >= 33) {
            onBackInvokedDispatcher.registerOnBackInvokedCallback(OnBackInvokedDispatcher.PRIORITY_DEFAULT) {
                if (canLeave) finish()
            }
        }
    }

    @Deprecated("Before Android 13")
    override fun onBackPressed() {
        if (canLeave) @Suppress("DEPRECATION") super.onBackPressed()
    }

    override fun onDestroy() {
        timer?.cancel()
        super.onDestroy()
    }
}
