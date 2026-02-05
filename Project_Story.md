# Our Story

## 💔 What Inspired Us

We are from Myanmar. Since the civil war began, countless young people have been displaced, separated from their families, and forced to navigate life alone in unfamiliar places. Even the strongest among us have bad days—moments when we break down, when the weight becomes too heavy to carry alone.

**We also face similar issues.** We need someone to listen, someone to talk to, someone we can chat with about ourselves without fear of judgment or consequences.

But reaching out for help isn't simple. Privacy concerns, language barriers, lack of money, cultural stigma, and the sheer absence of time make professional therapy nearly impossible for most. Making new friends in displacement is hard. Trusting strangers with your deepest fears is harder.

**We needed something different.** A safe space where you could get things off your chest without judgment. Where your thoughts stay yours. Where help is always available, even at 3 AM when you can't sleep because of nightmares or worry.

That's why we built **Anchor**—not for Silicon Valley investors or tech conferences, but for our friends back home. For everyone who's struggling alone and needs a place where their mind can safely land.

---

## 🧠 What We Learned

### About Technology

- **Gemini 3's power is real**: We were amazed at how well Gemini 3 understands emotional nuance. It doesn't just match keywords—it genuinely comprehends context, detects subtle signs of distress, and responds with appropriate empathy
- **On-device AI matters**: For users with limited internet or privacy concerns, having Llama 3.2 run entirely offline was crucial
- **Blockchain isn't just hype**: EthStorage gave our users something powerful—proof that their recovery journey exists permanently, that their progress can't be erased by governments or corporations

### About Mental Health

- **Journaling works**: Research validates it, but seeing users find clarity through guided prompts was profound
- **Gamification helps**: NFT rewards aren't just fun—they genuinely motivate consistency, which is critical for mental health recovery
- **Clinical tools are essential**: GAD-7 and PHQ-9 aren't perfect, but they give people a starting point to understand what they're experiencing

### About Ourselves

- Building something that could save lives is terrifying and inspiring at the same time
- We learned to balance technical ambition with user needs—sometimes simpler is better
- Most importantly: **technology alone can't solve mental health, but it can make support more accessible**

---

## 🛠️ How We Built It

### Phase 1: The Foundation

1. **Started with Flutter** because we needed one codebase for Android, iOS, and web—our users are scattered across different devices
2. **Integrated SQLite** for local, encrypted storage—privacy from day one
3. **Built the journaling system** with guided prompts based on therapeutic techniques

### Phase 2: The AI Brain

1. **Integrated Gemini 3 API** for cloud-based intelligence:
   - Carefully engineered prompts to ensure empathetic, clinically appropriate responses
   - Added emotional pattern recognition for journal analysis
   - Implemented risk assessment to identify crisis situations
2. **Added ExecuTorch + Llama 3.2** for users who need offline support:
   - Downloaded and optimized models for mobile devices
   - Created a hybrid system where users can choose their AI provider

### Phase 3: Clinical Features

1. **Implemented GAD-7 and PHQ-9 assessments** following clinical scoring guidelines
2. **Built tracking systems** to show progress over time
3. **Added severity-based recommendations** (e.g., "Consider reaching out to a professional")

### Phase 4: Blockchain Layer

1. **Integrated EthStorage** for permanent journal summary storage
2. **Deployed NFT smart contract** (ERC-721) for streak rewards
3. **Connected MetaMask/WalletConnect** using Reown AppKit for wallet authentication

### Phase 5: Polish

1. **Added 8 language translations** (including languages spoken in Myanmar and refugee communities)
2. **Implemented biometric security** (fingerprint, face unlock)
3. **Created gamification system** with milestone NFTs to encourage consistency

---

## 🚧 Challenges We Faced

### Technical Challenges

#### 1. Gemini 3 Integration Complexity

- **Problem**: Getting Gemini 3 to respond appropriately to mental health crises without being overly clinical or dismissive
- **Solution**: Spent weeks fine-tuning prompts, testing edge cases, and implementing safety guidelines. Added explicit instructions for crisis detection and resource provision

#### 2. On-Device AI Performance

- **Problem**: Llama 3.2 models are huge (1-3GB). Many users have limited storage and slow internet
- **Solution**: Implemented progressive download with pause/resume, optimized model loading, and created a "compact" vs "advanced" option based on device capabilities

#### 3. Blockchain + Mobile = Pain

- **Problem**: Wallet connections on mobile are notoriously buggy. WalletConnect sessions drop, transaction signing fails randomly
- **Solution**: Implemented robust error handling, retry logic, and clear user feedback. Added fallback mechanisms when blockchain features fail

#### 4. Privacy vs Features Trade-off

- **Problem**: Cloud AI (Gemini 3) provides better insights but requires sending data to Google. Blockchain provides permanence but puts data on a public ledger
- **Solution**: Made everything optional and transparent. Users choose: on-device only, cloud AI, or blockchain anchoring. We never force anyone to compromise privacy

### Non-Technical Challenges

#### 1. Emotional Weight

- **Problem**: Testing crisis detection features means exposing ourselves to dark content repeatedly. It took a toll on our own mental health
- **Solution**: We took breaks, supported each other, and reminded ourselves why we're building this

#### 2. Scope Creep

- **Problem**: We wanted to add so many features—meditation timers, peer support groups, AI therapist roleplay, etc.
- **Solution**: Focused on core value: journaling + assessment + AI companion + privacy. We can add more later if this helps people first

#### 3. Validation Without Clinical Expertise

- **Problem**: We're engineers, not therapists. How do we know we're not causing harm?
- **Solution**: Researched extensively, followed established clinical guidelines (GAD-7, PHQ-9), added disclaimers that we're not a replacement for professional help, and included crisis hotline resources

#### 4. Testing with Real Users

- **Problem**: Mental health is deeply personal. We couldn't just ask friends to "test the depression feature"
- **Solution**: Started with ourselves, then carefully reached out to trusted individuals who volunteered to help. Their feedback was invaluable and humbling

---

## 🌟 What Makes Us Proud

We're not just another chatbot wrapper. We built:

- ✅ A complete ecosystem that addresses real needs
- ✅ True privacy controls—users own their data
- ✅ Clinical-grade tools integrated with AI reasoning
- ✅ Gamification that actually motivates behavior change
- ✅ Cross-platform support so no one is left out

**Most importantly:** We built something that could genuinely help people like us, people who are struggling alone without access to traditional support systems.

---

## 🔮 What's Next

If Anchor helps even one person through a dark night, we've succeeded. But we dream bigger:

- Partner with humanitarian organizations serving displaced communities
- Add more languages (Burmese, Karen, other Myanmar languages)
- Integrate peer support features (carefully moderated)
- Expand to more mental health assessments (PTSD screening, etc.)
- Make it work fully offline for areas with no internet

**This isn't just a hackathon project for us. It's a mission.**

---

_For everyone who's ever felt alone in their struggle: We see you. We're with you. Your mind has a safe place to land._