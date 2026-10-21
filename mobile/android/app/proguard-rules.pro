# Glance creates action callbacks by reflection (no-argument constructor).
# Without this, R8 removes the constructor and widget buttons fail in
# release builds only.
-keep class * implements androidx.glance.appwidget.action.ActionCallback { <init>(); }
