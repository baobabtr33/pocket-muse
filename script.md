# Pocket Muse demo script: Orange County day

Muse thinks ahead for you. The night before, Muse (the big cloud model) plans your day and teaches a small model on your phone what you'll need. During the day, with no signal, Llama 3.2 1B answers on the phone in about a second, spoken in your Ray-Ban Meta glasses.

**The day** (pack `oc`, notes in `data/oc.md`):

1. Morning: study at the Newport Beach Central Library.
2. Midday: class at UC Irvine, then lunch at a dining hall.
3. Afternoon: tide pools and the Historic District at Crystal Cove State Park.
4. Sunset: bonfire at the Huntington Beach pier.

Length: about 3 minutes. Film through the glasses where you can; show the phone screen for answers.

## Before filming

- [ ] Rebuild the pack the day before, so the forecast and sunset are fresh: `uv run python pack.py --scenario oc`.
- [ ] Mac check: `uv run python eval.py --scenarios`. The `oc` day should pass.
- [ ] Install: `ios/run.sh --export`. Pick **Orange County day** on the Muse tab.
- [ ] Phone self-test: set Auto-Lock to Never, then `.claude/skills/verify-pocket-muse/scripts/pm.sh selftest`. Read what it *heard* as well as what it answered.
- [ ] Turn off "Hey Meta" in the Meta AI app, so the glasses' own assistant doesn't answer too.
- [ ] Turn on airplane mode (or "Simulate no signal" in Settings) for every offline scene.

## Scenes

### 1. Library, online (0:00 to 0:25)

**Shot.** Laptop at a table in the Newport Beach Central Library.

**Ask (online):** "Explain eigenvalues and eigenvectors intuitively, with a 2x2 example."

Big Muse answers from the cloud.

**Say:** "Muse already knows my day. Library this morning, class and lunch at UC Irvine, Crystal Cove this afternoon, a bonfire at Huntington Beach tonight. Last night it thought ahead about what I'd need, and taught my phone."

### 2. Privacy (0:25 to 0:45)

**Say:** "Muse knowing my schedule is private by design. Meta built Private Processing so that personal context from AI glasses is processed in confidential virtual machines that even Meta can't see into. And once the pack is on my phone, every question I ask in the moment stays on the device. It's answered locally, never sent anywhere."

Careful. This prototype builds the pack through Baseten's API, not Private Processing. Say the first half as the product design. The second half is true today: speech recognition, retrieval and Llama all run on the phone.

### 3. Leaving the library, no signal (0:45 to 1:00)

**Ask:** "Hey Meta, what time does the library close today?"

**Expect:** today's hours. Monday to Thursday 9am to 9pm, Friday and Saturday 9am to 6pm, Sunday noon to 5pm.

### 4. UC Irvine, after class (1:00 to 1:20)

**Ask:** "Hey Meta, where can I get lunch on campus and when is it open?"

**Expect:** The Anteatery (Mesa Court) or Brandywine (Middle Earth), lunch 11:30am to 2:00pm.

**Film:** lunch through the glasses.

### 5. Crystal Cove tide pools (1:20 to 1:45)

**Ask:** "Hey Meta, can I take a shell home from the tide pools?"

**Expect:** No. Collecting shells, rocks or anything natural is prohibited; look but don't touch.

**Optional:** "How much is parking at Crystal Cove?" ($5 an hour at Los Trancos, $15 a day at the other lots.)

### 6. Huntington Beach at sunset (1:45 to 2:15)

**Ask, standing at the water:** "Hey Meta, I'm getting pulled out by the water, what do I do?"

**Expect:** Don't fight the current, swim parallel to shore, then wave for a lifeguard.

**Ask:** "Hey Meta, where are the fire pits?"

**Expect:** 127 fire pits from south of First Street to Beach Blvd.

**Ask:** "What time is sunset today?"

**Expect:** the exact time from the forecast snapshot, and that it's the forecast as of last night.

### 7. Off-pack question, no signal (2:15 to 2:25)

**Ask:** "What's the score of the Lakers game?"

**Expect:** "That's not in your pack, and there's no signal. I'll ask Muse when you're back online." It's queued, not guessed. Turn signal back on and show the queued question answered by big Muse.

### 8. How it works (2:25 to 3:00)

**Show:** the app's Pack tab, then the How tab.

**Say:** "Muse Spark wrote safety cards first, explained why, and wrote about 450 practice questions for about a quarter. Llama 3.2 1B learned them as a 23 megabyte add-on."

**Why distill, not paste the pack in? One number:** the same 1B model with the whole pack in its prompt and no training passed 13 of 35 spoken tests. It refused facts that were right in front of it and wrote a pizza poem anyway. After Muse taught it, 32 of 35.

**Say:** "Muse doesn't just hand the small model notes. It teaches it how to use them: say what the pack says, and say 'I'll ask Muse later' for everything else."

## If something goes wrong

- **Voice misfires.** The scene menu (bottom left on the Muse tab) runs each scene's question with one tap.
- **A wrong answer on camera.** Cut and retake; packs are fixed, so the same question gives the same answer.
- **Glasses audio drops.** The phone speaks the answer too; film the phone screen.
- **Facts changed.** Hours and prices come from official pages checked on 2026-11-01. Fix `data/oc.md` and rebuild.

## Sources for the notes

- Newport Beach Central Library: https://www.newportbeachlibrary.org/about/hours-and-locations/central-library
- Crystal Cove State Park: https://www.parks.ca.gov/?page_id=644 and its visitor info sheet (parks.ca.gov/pages/644/files/CrystalCoveSP_Infosheet_85x14_021825_FINAL.pdf)
- Huntington Beach beach information: https://www.huntingtonbeachca.gov/departments/parks_recreation/beach_information/index.php
- UC Irvine Dining: uci.mydininghub.com
