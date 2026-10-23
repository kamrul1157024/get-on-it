package app.getonit.nudge

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

class NudgeRulesTest {
    private val work = PendingWork("atomic-habits", "Read Atomic Habits", "Read p. 45–46 · ≈ 4 min", "getonit://start/atomic-habits")
    private val insta = WatchedApp("com.instagram.android", "Instagram", 15)
    private val base = NudgeConfig(enabled = true, apps = listOf(insta), pending = listOf(work))
    private val noon = 12 * 60
    private val t0 = 1_800_000_000_000L

    private fun decide(c: NudgeConfig = base, h: NudgeHistory = NudgeHistory(), trigger: Trigger = Trigger.Unlock(), nowMs: Long = t0, minute: Int = noon) =
        NudgeRules.decide(c, h, trigger, "2026-10-21", nowMs, minute)

    @Test fun aNudgeGoesWhenItsGoalHasNoOpenWork() {
        assertEquals(true, NudgeRules.shownMayStay(null, emptyList()))
        assertEquals(true, NudgeRules.shownMayStay("atomic-habits", listOf(work)))
        // Deleted, or done today: the goal is no longer in the pending list.
        assertEquals(false, NudgeRules.shownMayStay("atomic-habits", emptyList()))
        assertEquals(false, NudgeRules.shownMayStay("gone", listOf(work)))
    }

    @Test fun unlockNudgesWithTheFirstOpenWork() {
        val (nudge, h) = decide()
        assertNotNull(nudge)
        assertEquals("Read Atomic Habits", nudge!!.title)
        assertEquals("getonit://start/atomic-habits", nudge.work.link)
        assertEquals(1, h.count)
    }

    @Test fun nothingWhenOffDoneOrQuiet() {
        assertNull(decide(c = base.copy(enabled = false)).first)
        assertNull(decide(c = base.copy(pending = emptyList())).first)
        assertNull(decide(minute = 23 * 60 + 30).first)
        assertNull(decide(minute = 6 * 60).first)
        assertNull(decide(c = base.copy(unlock = false)).first)
    }

    @Test fun twoHoursBetweenNudgesAndFourADay() {
        val (_, h1) = decide()
        assertNull(decide(h = h1, nowMs = t0 + 60 * 60_000L).first)
        val (second, h2) = decide(h = h1, nowMs = t0 + 121 * 60_000L)
        assertNotNull(second)
        val full = h2.copy(count = 4)
        assertNull(decide(h = full, nowMs = t0 + 600 * 60_000L).first)
    }

    @Test fun aNewDayStartsAFreshCount() {
        val old = NudgeHistory(day = "2026-10-20", count = 4, lastAtMs = t0)
        val (nudge, h) = decide(h = old, nowMs = t0 + 1)
        assertNotNull(nudge)
        assertEquals("2026-10-21", h.day)
        assertEquals(1, h.count)
    }

    @Test fun usageNudgesOncePerThresholdStep() {
        assertNull(decide(trigger = Trigger.Usage(insta, 14)).first)
        val (nudge, h) = decide(trigger = Trigger.Usage(insta, 16))
        assertEquals("16 min on Instagram today", nudge!!.title)
        assertEquals("Read p. 45–46 · ≈ 4 min", nudge.body)
        val later = t0 + 130 * 60_000L
        assertNull(decide(h = h, trigger = Trigger.Usage(insta, 25), nowMs = later).first)
        assertNotNull(decide(h = h, trigger = Trigger.Usage(insta, 31), nowMs = later).first)
    }

    @Test fun quietHoursCanBeAnInsideRange() {
        val c = base.copy(quietStartMin = 12 * 60, quietEndMin = 14 * 60)
        assertNull(decide(c = c, minute = 13 * 60).first)
        assertNotNull(decide(c = c, minute = 15 * 60).first)
    }

    private val lecture = Equivalent(75.0, "CS229 lecture", "CS229 lectures")
    private val page = Equivalent(2.0, "page of Atomic Habits", "pages of Atomic Habits")

    @Test fun durationsReadLikeAPerson() {
        assertEquals("5 min", Wording.duration(5))
        assertEquals("1 h", Wording.duration(60))
        assertEquals("1 h 20 min", Wording.duration(80))
    }

    @Test fun theVerbFollowsTheAppCategory() {
        assertEquals("scrolling Instagram", Wording.doing("social", "Instagram"))
        assertEquals("watching YouTube", Wording.doing("video", "YouTube"))
        assertEquals("playing Candy Crush", Wording.doing("game", "Candy Crush"))
        assertEquals("reading news on BBC", Wording.doing("news", "BBC"))
        assertEquals("on Chrome", Wording.doing("", "Chrome"))
    }

    @Test fun lostTimeIsToldInTheUnitsOfOpenGoals() {
        assertEquals("2 CS229 lectures, or 80 pages of Atomic Habits", Wording.couldHave(160, listOf(lecture, page)))
        assertEquals("1 CS229 lecture, or 40 pages of Atomic Habits", Wording.couldHave(80, listOf(lecture, page)))
        // A unit that does not fit once is left out; none fitting gives null.
        assertEquals("15 pages of Atomic Habits", Wording.couldHave(30, listOf(lecture, page)))
        assertNull(Wording.couldHave(1, listOf(lecture, page)))
        assertNull(Wording.couldHave(500, emptyList()))
        // At most two goals.
        assertEquals("2 CS229 lectures, or 80 pages of Atomic Habits", Wording.couldHave(160, listOf(lecture, page, lecture)))
    }

    @Test fun usageNudgeSaysWhatTheTimeCouldHaveBeen() {
        val social = insta.copy(category = "social")
        val c = base.copy(equivalents = listOf(lecture, page))
        val (nudge, _) = decide(c = c, trigger = Trigger.Usage(social, 80))
        assertEquals("1 h 20 min scrolling Instagram today", nudge!!.title)
        assertEquals("That was 1 CS229 lecture, or 40 pages of Atomic Habits. Do the thing.", nudge.body)
        // No goal unit fits: the open work, as before.
        val (short, _) = decide(c = base, trigger = Trigger.Usage(social, 16))
        assertEquals("Read p. 45–46 · ≈ 4 min", short!!.body)
    }

    @Test fun unlockMentionsLostTimeFromHalfAnHour() {
        val c = base.copy(equivalents = listOf(lecture))
        assertEquals("Read p. 45–46 · ≈ 4 min", decide(c = c, trigger = Trigger.Unlock(29)).first!!.body)
        assertEquals(
            "45 min lost today. One CS229 lecture is 1 h 15 min. Read p. 45–46 · ≈ 4 min",
            decide(c = c, trigger = Trigger.Unlock(45)).first!!.body,
        )
        assertEquals(
            "2 h 30 min lost today. That is 2 CS229 lectures. Read p. 45–46 · ≈ 4 min",
            decide(c = c, trigger = Trigger.Unlock(150)).first!!.body,
        )
        assertEquals("45 min lost today. Read p. 45–46 · ≈ 4 min", decide(trigger = Trigger.Unlock(45)).first!!.body)
        // The limits still hold.
        assertNull(decide(c = c, trigger = Trigger.Unlock(45), minute = 23 * 60 + 30).first)
    }

    @Test fun eachStrengthHasItsLimits() {
        val gentle = base.copy(strength = Strength.GENTLE)
        val (_, g1) = decide(c = gentle)
        assertNull("3 h between gentle nudges", decide(c = gentle, h = g1, nowMs = t0 + 150 * 60_000L).first)
        assertNotNull(decide(c = gentle, h = g1, nowMs = t0 + 181 * 60_000L).first)
        assertNull("2 a day", decide(c = gentle, h = g1.copy(count = 2), nowMs = t0 + 600 * 60_000L).first)

        val hard = base.copy(strength = Strength.HARD)
        val (_, h1) = decide(c = hard)
        assertNull("20 min between hard nudges", decide(c = hard, h = h1, nowMs = t0 + 19 * 60_000L).first)
        assertNotNull(decide(c = hard, h = h1, nowMs = t0 + 21 * 60_000L).first)
        assertNotNull(decide(c = hard, h = h1.copy(count = 11), nowMs = t0 + 30 * 60_000L).first)
        assertNull("12 a day", decide(c = hard, h = h1.copy(count = 12), nowMs = t0 + 30 * 60_000L).first)
        assertEquals(Strength.FIRM, Strength.parse(null))
        assertEquals(Strength.FIRM, Strength.parse("firm"))
    }

    @Test fun theToneFollowsTheStrength() {
        val social = insta.copy(category = "social")
        val units = listOf(lecture)
        val gentle = decide(c = base.copy(strength = Strength.GENTLE, equivalents = units), trigger = Trigger.Usage(social, 80)).first!!
        assertEquals("Ready for your goal?", gentle.title)
        assertEquals("1 h 20 min on Instagram so far. Read Atomic Habits is waiting.", gentle.body)
        assertEquals(false, gentle.stopScreen)

        val firm = decide(c = base.copy(equivalents = units), trigger = Trigger.Usage(social, 45)).first!!
        assertEquals("45 min scrolling Instagram today", firm.title)
        assertEquals(false, firm.stopScreen)

        val hard = decide(c = base.copy(strength = Strength.HARD, equivalents = units), trigger = Trigger.Usage(social, 160)).first!!
        assertEquals("2 h 40 min burned on Instagram", hard.title)
        assertEquals("That was 2 CS229 lectures. Close it. Do the thing.", hard.body)
        assertEquals(true, hard.stopScreen)
        assertEquals("com.instagram.android", hard.app!!.packageName)

        // Gentle unlock nudges do not mention lost time; hard ones are blunt.
        assertEquals("Read p. 45–46 · ≈ 4 min", decide(c = base.copy(strength = Strength.GENTLE), trigger = Trigger.Unlock(90)).first!!.body)
        assertEquals(
            "1 h 30 min lost today. That is 1 CS229 lecture. Close it and do the thing. Read p. 45–46 · ≈ 4 min",
            decide(c = base.copy(strength = Strength.HARD, equivalents = units), trigger = Trigger.Unlock(90)).first!!.body,
        )
    }

    @Test fun aBreakPausesNudgesForAnHour() {
        val paused = NudgeHistory().breakFor(t0, "2026-10-21")
        assertNull(decide(h = paused, nowMs = t0 + 59 * 60_000L).first)
        assertNotNull(decide(h = paused, nowMs = t0 + 61 * 60_000L).first)
        // Every level, and quiet hours and done work still stop nudges.
        assertNull(decide(c = base.copy(strength = Strength.HARD), h = paused, nowMs = t0 + 30 * 60_000L).first)
        assertNull(decide(c = base.copy(strength = Strength.HARD), minute = 23 * 60 + 30).first)
        assertNull(decide(c = base.copy(strength = Strength.HARD, pending = emptyList())).first)
    }

    @Test fun timeBiggerThanAGoalCountsWholeGoals() {
        val course = Equivalent(75.0, "CS229 lecture", "CS229 lectures", wholeMinutes = 1900.0, whole = "the whole course")
        assertEquals("1 CS229 lecture", Wording.couldHave(80, listOf(course)))
        assertEquals("25 CS229 lectures, or the whole course", Wording.couldHave(1900, listOf(course)))
        assertEquals("76 CS229 lectures, or the whole course 3 times", Wording.couldHave(5760, listOf(course)))
    }
}
