# 1-screen.R

library(edwr)
library(tidyverse)
library(lubridate)
library(stringr)

data_raw <- "data/raw"

# potential patients -----------------------------------

# Run EDW query: Patients - by Unit Admission
#   * Person Location - Nurse Unit (To):
#       - Cullen 2 E Medical Intensive Care Unit
#       - HVI Cardiovascular Intensive Care Unit
#       - HVI Cardiac Care Unit
#       - Hermann 3 Shock Trauma Intensive Care Unit
#       - Hermann 3 Transplant Surgical ICU
#       - Jones 7 J Elective Neuro ICU
#       - Jones 7 Neuro Trauma ICU
#   * Person Location- Facility (Curr): Memorial Hermann Hospital
#   * Admit date range: User-Defined
#   * Admit begin: 7/1/2014 00:00:00
#   * Admit end: 7/1/2016 00:00:00

screen <- read_data(data_raw, "screen") %>%
    as.patients() %>%
    filter(discharge.datetime <= ymd("2016-06-30", tz = "US/Central"),
           age >= 18) %>%
    arrange(pie.id)

pie <- concat_encounters(screen$pie.id, 910)

# demographics -----------------------------------------

# Run EDW Query: Demographics
#   * PowerInsight Encounter Id: all values from object pie

demograph <- read_data(data_raw, "demographics") %>%
    as.demographics()

# remove any discharge to court/law
excl_prison <- demograph %>%
    filter(disposition %in% c("DC/TF TO COURT/LAW", "Court/Law Enforcement"))

demograph <- anti_join(demograph, excl_prison, by = "pie.id")

# keep only the first admission for any individual patient
eligible <- demograph %>%
    group_by(person.id) %>%
    inner_join(screen, by = "pie.id") %>%
    arrange(person.id, discharge.datetime) %>%
    summarize(pie.id = first(pie.id)) %>%
    arrange(pie.id)

excl_reencounter <- anti_join(demograph, eligible, by = "pie.id")

pie2 <- concat_encounters(eligible$pie.id)

# ICD codes --------------------------------------------

# Run EDW Query: Diagnosis Codes (ICD-9/10-CM) - All
#   * PowerInsight Encounter Id: all values from object pie2
icd_codes <- read_data(data_raw, "diagnosis") %>%
    as.diagnosis() %>%
    tidy_data()

# remove patients with both ICD9 and ICD10 codes
excl_icd <- icd_codes %>%
    distinct(pie.id, icd9) %>%
    group_by(pie.id) %>%
    summarize(n = n()) %>%
    filter(n > 1)

eligible <- anti_join(eligible, excl_icd, by = "pie.id")

# pregnancy --------------------------------------------

female <- demograph %>%
    semi_join(eligible, by = "pie.id") %>%
    filter(sex == "Female") %>%
    arrange(pie.id)

pie3 <- concat_encounters(female$pie.id)

# Run EDW Query: Labs - Pregnancy
#   * PowerInsight Encounter Id: all values from object pie3

preg_lab <- read_data(data_raw, "preg") %>%
    as.labs() %>%
    check_pregnant()

excl_preg <- icd_codes %>%
    semi_join(female, by = "pie.id") %>%
    check_pregnant() %>%
    full_join(preg_lab, by = "pie.id") %>%
    distinct

eligible <- anti_join(eligible, excl_preg, by = "pie.id")

pie4 <- concat_encounters(eligible$pie.id, 950)

# hospital locations -----------------------------------

# Run EDW Query: Location History
#   * PowerInsight Encounter Id: all values from object pie4

# list of ICU's
icu <- c("HVI Cardiovascular Intensive Care Unit",
         "Cullen 2 E Medical Intensive Care Unit",
         "Jones 7 J Elective Neuro ICU",
         "Hermann 3 Shock Trauma Intensive Care Unit",
         "Hermann 3 Transplant Surgical ICU",
         "HVI Cardiac Care Unit")

icu_admit <- read_data(data_raw, "locations") %>%
    as.locations() %>%
    tidy_data() %>%
    filter(location %in% icu) %>%
    arrange(pie.id, arrive.datetime) %>%
    group_by(pie.id) %>%
    distinct(.keep_all = TRUE) %>%
    filter(unit.length.stay > 0.5)

excl_icu_short <- anti_join(eligible, icu_admit, by = "pie.id")

eligible <- semi_join(eligible, icu_admit, by = "pie.id")

pie5 <- concat_encounters(eligible$pie.id, 975)

# labs -------------------------------------------------

# Run EDW Query: Clinical Events - Prompt
#   * PowerInsight Encounter Id: all values from object pie5
#   * Clinical Event:
#       - Sodium Lvl
#       - Potassium Lvl
#       - CO2
#       - Creatinine Lvl
#       - BUN
#       - Glucose Lvl
#       - Albumin Lvl
#       - Bilirubin Total
#       - Bili Total
#       - POC A pH
#       - POC A PCO2
#       - POC A PO2
#       - WBC (multiple matching)
#       - Hct
#       - HCT

labs <- read_data(data_raw, "labs_apache") %>%
    as.labs() %>%
    tidy_data() %>%
    inner_join(icu_admit, by = "pie.id") %>%
    filter(lab.datetime >= arrive.datetime,
           lab.datetime <= arrive.datetime + hours(24),
           lab.datetime <= depart.datetime) %>%
    mutate(lab = str_replace_all(lab, " lvl", ""),
           lab = str_replace_all(lab, "poc a", "arterial"),
           lab = str_replace_all(lab, "bilirubin", "bili"),
           lab = str_replace_all(lab, " ", "_")) %>%
    group_by(pie.id, lab) %>%
    summarize(min = min(lab.result)) %>%
    spread(lab, min) %>%
    drop_na()

excl_labs <- anti_join(eligible, labs, by = "pie.id")

eligible <- semi_join(eligible, labs, by = "pie.id")

# pie6 <- concat_encounters(eligible$pie.id)

# check_icd <- icd_codes %>%
#     semi_join(labs.all, by = "pie.id") %>%
#     distinct(pie.id, icd9) %>%
#     count(icd9)

# save files -------------------------------------------

exclude <- list(screen = nrow(screen),
                prisoners = nrow(excl_prison),
                pregnant = nrow(excl_preg),
                mult_icd_types = nrow(excl_icd),
                icu_short = nrow(excl_icu_short),
                labs_missing = nrow(excl_labs),
                reencounter = nrow(excl_reencounter))

saveRDS(eligible, "data/tidy/eligible.Rds")
saveRDS(icu_admit, "data/tidy/icu_admit.Rds")
saveRDS(exclude, "data/final/exclude.Rds")

# need to add: VBGs;

# apply exclusion criteria; randomly select 100 each with ICD-9-CM and ICD-10-CM codes
