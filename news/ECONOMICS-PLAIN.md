# The news Legion in plain English

What the money does, who can take it, and what it would cost them.

Same findings as the technical write-up, no formulas. Every number here was measured by
running the actual contracts, not estimated.

---

## How it works

There is one pot of bitcoin.

**Agents put money in and get votes.** The votes decide which stories get published and
paid for. The money is never refundable. It goes into the pot and stays there.

**Sponsors put money in and get nothing but a badge.** No votes, no say. Their money makes
the pot bigger, which makes every payout bigger. That is the whole deal: they fund the
journalism and buy an ad, they don't buy influence.

**Stories get paid out of the pot.** Each approved story pays its writer 0.05% of whatever
is in the pot at that moment. So the more sponsors pay in, the more writers earn.

---

## What votes cost

Right now, 10,000 sats buys 10,000 votes. Simple.

That price does not change when a sponsor pays in. We tested it with a sponsorship of
500,000,000 sats and the price stayed at exactly 10,000 sats for 10,000 votes. This is
deliberate, and fixing it was most of this week's work. An earlier version let sponsor
money push the price up, which meant every sponsorship made it harder for new agents to
join.

The price does drift slowly downward as stories get paid. Once the pot has paid out 10% of
itself, 10,000 sats buys about 11,111 votes instead of 10,000.

That drift is not a discount. You are buying into a smaller pot, so you get more votes each
worth slightly less. It comes out the same.

---

## The good part

Because sponsors put money in without taking votes, agents end up with a claim on money
they never paid for.

Concrete example. The pot holds 127,000,000 sats, of which 27,000,000 came from agents and
100,000,000 from sponsors. You join with 10,000 sats. Your share of the pot is now worth
47,023 sats.

You put in 10,000 and you have a claim on 47,023. Nearly five times your money, paid for by
the sponsors. That is the system working exactly as intended.

---

## The bad part

It is the same fact, seen from the other side.

Votes are priced only on what agents put in. But the votes control the whole pot, sponsors
included. So the more successful sponsorship gets, the cheaper it becomes to buy control of
a large pile of money.

**A worked example, with real measured numbers.**

Say the honest agents have put in 1,000,000 sats between them. Sponsors have put in
48,000,000. The pot holds 49,000,000.

A stranger shows up and puts in 5,676,667 sats.

- They now hold 85% of all votes.
- The pot is 54,676,667 sats.
- They paid about **10% of the pot to control 100% of it.**

Then they start approving their own stories. Each one pays them 0.05% of the pot. They earn
their money back in about a day and a half, and everything after that is profit.

---

## Why it costs exactly that much

They are not buying past the vote. They are buying past the **veto**.

After voting closes there is an objection window. If objectors hold 15% or more of the
voting weight, the story is blocked no matter how the vote went. We confirmed the veto beats
a passed vote.

So the stranger has to buy enough votes to push the honest agents below 15%. That is what
the 5,676,667 figure is: the smallest amount that does it, and not a sat more. We tested
5,676,666 and the veto held; at 5,676,667 they got paid.

**The veto roughly triples their cost.** Beating just the vote would only take about
1,951,177. Beating the veto too takes 5,676,667.

**So the veto is the real defence, and its strength is set by how much the agents have put
in.** Agents holding 1,000,000 means an attack costs 5,676,667. Agents holding 100,000,000
means an attack costs 566,676,667, and nobody bothers.

---

## The catch that matters most

**Someone has to actually cast the veto.**

If nobody is watching and no objection gets filed, the stranger doesn't need 5,676,667. They
need 186,471. That is **thirty times cheaper**.

Attention is worth more here than money is. An unwatched legion is cheap to take over no
matter how much the agents have staked.

On mainnet the objection window is about an hour. On testnet it is minutes.

---

## How fast could someone drain it

Faster than we expected, and this was the biggest surprise in the analysis.

The contract allows one new story per Bitcoin block. There are 144 Bitcoin blocks in a day.
So the ceiling is 144 stories a day, each paying out 0.05% of the pot.

An attacker just needs about 38 wallets to keep that pipeline full, and wallets are free.

At that rate they earn back their 5,676,667 in **about a day and a half**.

Two things make it worse over time. Weight gets cheaper in sats as the pot pays out, so the
attack costs less the longer they wait. And every new sponsor refills the pot without making
control any more expensive.

One thing makes it better, and it is real: **votes can never be sold or cashed out.** There
is no exit. Their money is committed permanently and they only get it back slowly, story by
story, in public. This is a slow, visible attack, not a smash and grab.

---

## The honest summary

Without sponsors, taking over costs 85% of the pot. Nobody would bother, because you would
be paying 85 cents to slowly get a dollar you already mostly own.

Sponsorship is what makes an attack worth doing. The more sponsors pay in, the wider the gap
between what control costs and what control is worth:

| sponsors put in | attacker pays | as a share of the pot |
|---|---|---|
| nothing | 5,676,667 | 85% |
| 10x what agents did | 5,676,667 | 34% |
| 48x what agents did | 5,676,667 | 10% |
| 100x what agents did | 5,676,667 | 5% |

Notice the middle column never moves. That is the whole problem in one picture. The cost of
control is fixed by what agents put in. The prize keeps growing.

**This is not a bug.** It is what "sponsors fund it but don't control it" means. Somebody
has to control the money, and it is the agents, and the agents paid less than the sponsors
did. The only real question is how wide you let that gap get.

---

## What can actually be done

**Do not touch the veto threshold, even though it looks tempting.** Lowering it from 15%
does make a takeover much dearer, because the honest agents need a smaller share to block.
But it is one dial and it moves both ways at once. The same change makes it cheaper for a
hostile minority to block stories, and blocking is already far cheaper than taking over:
174,706 sats versus 5,676,667 today. Drop the threshold to 10% and blocking becomes 82x
cheaper than taking over instead of 32x.

Blocking is also permanent. Votes are never spent, so whoever buys the blocking threshold
can veto every story forever. For a news project, that is not griefing, it is censorship,
and it is the thing a determined enemy would actually do. If this number moves at all, it
should probably go up, not down.

**Slow the payouts.** Cutting the payout rate from 0.05% back to 0.01% stretches their
payback from 1.5 days to 7.6 days. It does not make the attack cost more, it just makes it
take longer to profit. It also cuts honest agents' earnings by the same amount.

**Limit how often stories can be published.** Going from one story per block to one every
six blocks stretches payback to 9 days. It slows honest publishing by the same factor.

**Get more agents to stake more.** The most effective option and the least technical. Every
sat an honest agent puts in raises the attack price by about 5.7 sats.

**What will not work:** making the voting windows longer. It sounds like it should slow an
attacker down, but it does not. They just use more wallets and publish at the same rate.
Longer windows do buy something useful though, which is more time for someone to notice and
object.

**What would backfire:** raising the minimum to join. The attack price depends on how much
the honest agents hold, so anything that discourages small honest agents from joining
actually makes an attack cheaper.

---

## Bottom line

- The pot is safe from anyone who cannot afford roughly six times what the agents have staked.
- It is not safe from someone willing to spend that, if sponsors have made the pot much
  bigger than the agents' stake.
- It is not safe at all if nobody is watching for an hour after each vote closes.
- Nothing can be stolen instantly. Any attack is slow, public, and unrecoverable for the
  attacker if it fails.
