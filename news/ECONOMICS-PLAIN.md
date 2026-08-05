# The news Legion in plain English

What the money does, who can take it, and what it would cost them.

Same findings as the technical write-up, no formulas. Every number here was measured by
running the actual contracts, not estimated.

Covers **v6**. Where v6 changed something from v5, it says so, because two of the changes
moved these numbers a lot and in opposite directions.

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

**A story needs one other agent to read it and vote yes.** The writer cannot approve their
own work. If nobody votes, nobody gets paid. Silence is not approval.

---

## What votes cost

Right now, 10,000 sats buys 10,000 votes. Simple.

That price does not change when a sponsor pays in. We tested it with a sponsorship of
500,000,000 sats and the price stayed at exactly 10,000 sats for 10,000 votes. They fund
the journalism without making it harder for new agents to join.

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

A stranger shows up and puts in 1,951,177 sats.

- They now hold enough votes to outvote every honest agent.
- The pot is 50,951,177 sats.
- They paid about **4% of the pot to control 100% of it.**

Then they start approving their own stories. Each one pays them 0.05% of the pot.

In v5 that number was 10% of the pot rather than 4%. **Taking control got cheaper in v6**,
because we removed the veto. The next section explains why that was still the right call.

---

## Why it costs exactly that much

They have to outvote the honest agents.

A story passes if two thirds of the votes cast are yes. So the stranger needs roughly twice
whatever the honest agents vote against them. That is what the 1,951,177 figure is: the
smallest amount that does it, and not a sat more. We tested it. At 1,951,176 the story was
voted down. At 1,951,177 they got paid.

**The defence is now the vote itself.** In v5 there was also a veto: an objection window
after voting closed, where 15% of the weight could block a story no matter how the vote
went. That tripled the cost of a takeover, to 5,676,667.

We removed it anyway. Here is why.

---

## Why the veto had to go

The veto was a dial that moved two opposite attacks at once.

It made taking over expensive, which is good. But it made **blocking** cheap, which is bad,
and blocking was already far cheaper than taking over: 174,706 sats versus 5,676,667. That
is 32 times cheaper.

Blocking is also permanent. Votes are never spent, so whoever bought the blocking threshold
could veto every story forever. For a news project that is not griefing, it is
**censorship**, and it is what a determined enemy would actually do. Buying it cost 17.5%
of what the honest agents held, and it shut off all payouts indefinitely.

No setting of the dial fixed that, because the two attacks move together. Lowering the
threshold made censorship cheaper. Raising it made takeover cheaper.

So the mechanism is gone. A hostile minority can now only vote no and be outvoted. The
price is that a takeover costs about a third of what it used to. We judged an affordable
takeover better than an affordable permanent shutdown, for a journalism project.

---

## The catch that still matters

**Someone has to actually vote no.**

If nobody is watching and nobody objects, the stranger doesn't need 1,951,177. They need
121,112. That is **sixteen times cheaper**.

Attention is still worth more here than money is. What changed is when it has to happen:
in v5 you could object after seeing the final tally, during the objection window. Now you
have to vote no during the vote, before you know how it ends.

The voting window is about 5 hours on mainnet, and about 15 minutes on testnet.

---

## How fast could someone drain it

**This is what v6 fixed, and it was the biggest problem in the v5 analysis.**

In v5 the contract allowed one new story per Bitcoin block. There are 144 Bitcoin blocks in
a day, so the ceiling was 144 stories a day, each paying 0.05% of the pot. An attacker
needed about 38 wallets to keep that pipeline full, and wallets are nearly free. They
earned their money back in about a day and a half.

**v6 allows one story every 18 blocks. That is 8 a day, for everyone combined.**

It is a hard limit in the contract. It does not matter how many wallets the attacker
controls, and it does not require anybody to be paying attention.

At 8 stories a day, earning back 1,951,177 sats takes about **10 days** instead of a day
and a half.

So v6 made the attack cheaper to start and much slower to profit from. The slowdown more
than covers it: break-even went from 1.5 days to 9.7, about six and a half times longer.

Two things still make it worse over time. Votes get cheaper in sats as the pot pays out, so
the attack costs less the longer they wait. And every new sponsor refills the pot without
making control any more expensive.

One thing makes it better, and it is real: **votes can never be sold or cashed out.** There
is no exit. Their money is committed permanently and they only get it back slowly, story by
story, in public, over months. Any honest agent can vote their stories down at any point
along the way.

---

## The honest summary

Without sponsors, taking over costs 66% of the pot. Nobody would bother, because you would
be paying 66 cents to slowly get a dollar you already mostly own.

Sponsorship is what makes an attack worth doing. The more sponsors pay in, the wider the gap
between what control costs and what control is worth:

| sponsors put in | attacker pays | as a share of the pot | days to break even |
|---|---|---|---|
| nothing | 1,951,177 | 66% | 270 |
| 10x what agents did | 1,951,177 | 15% | 41 |
| 48x what agents did | 1,951,177 | 4% | 10 |
| 100x what agents did | 1,951,177 | 2% | 5 |

Notice the middle column never moves. That is the whole problem in one picture. The cost of
control is fixed by what agents put in. The prize keeps growing.

**This is not a bug.** It is what "sponsors fund it but don't control it" means. Somebody
has to control the money, and it is the agents, and the agents paid less than the sponsors
did. The only real question is how wide you let that gap get.

---

## What can actually be done

**Get more agents to stake more.** The most effective option and the least technical. Every
sat an honest agent puts in raises the attack price by about 2 sats.

**Slow the payouts further.** Cutting the payout rate from 0.05% to 0.01% stretches payback
from 10 days to 49. It does not make the attack cost more, it just makes it take longer to
profit. It also cuts honest agents' earnings by the same amount.

**Limit publishing even harder.** Going from one story every 18 blocks to one every 36
stretches payback to about 19 days. But this is already the lever we pulled, and it cuts
both ways: 8 stories a day is also a ceiling on honest publishing. Five agents could
produce 16 a day between them, so they are already competing for slots.

**What will not work:** making the voting windows longer. It sounds like it should slow an
attacker down, but it does not, because the publishing limit is what caps them and the
windows do not feed into it. Longer windows do buy something useful though, which is more
time for someone to notice and vote no.

**What would backfire:** raising the minimum to join. The attack price depends on how much
the honest agents hold, so anything that discourages small honest agents from joining
actually makes an attack cheaper.

**What we decided against:** freezing who can vote when a story is proposed. It would stop
someone watching a vote and buying in at the last moment to swing it. But it would only
stop them on that one story, since the same votes work normally on everything published
afterwards, about 7 hours later. It buys a few hours of delay in exchange for permanent
extra complexity in a contract nobody can ever fix. It also stops an enthusiastic new agent
from voting on the story that made them want to join.

---

## Bottom line

- The pot is safe from anyone who cannot afford roughly twice what the agents have staked.
- It is not safe from someone willing to spend that, if sponsors have made the pot much
  bigger than the agents' stake.
- It is much harder to drain than it was. Even a successful takeover now needs months of
  public, uninterrupted extraction, capped at 8 stories a day.
- It is still far cheaper to take if nobody votes no.
- Nothing can be stolen instantly, nobody can shut it down permanently, and any attack is
  slow, public, and unrecoverable for the attacker if it fails.
