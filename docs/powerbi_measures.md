# Power BI Measures

All DAX measures in the Coptic Analytics report, why each one exists, and
where it is used. The model is the gold-layer star schema imported from
Databricks; `fact_attendance` holds one row per member per event.

## Attendance

| Measure | Why | Used in |
|---|---|---|
| `Expected` | Base count of attendance rows — every member expected at an event. The other attendance measures filter it. | Building block only |
| `Present` | Rows marked present. | Input to `Attendance Rate` |
| `Absent` | Rows marked absent. | Input to `Attendance Rate` |
| `Not Marked` | Rows the servant has not marked yet, kept separate so they are not mistaken for absences. | Not shown on the current pages |
| `Attendance Rate` | Share of marked events the member attended. Unmarked events are excluded, so a late register does not look like a drop in attendance. | Overview and Church trend lines, Top 10 Members, Department trend by department, Attendance Rate by Activity, Need Follow Up table |
| `Last Present Date` | Most recent event a member attended — tells a servant how long someone has been away. | Need Follow Up table (Department page) |
| `Birthday This Month` | Flags members whose birthday falls in the current month and who are active in the selected filters. Returns 1/0 so it can be used as a visual filter. | Birthdays This Month table (Church page), filtered to 1 |

```dax
Expected = COUNTROWS ( fact_attendance )

Present = CALCULATE ( [Expected], fact_attendance[attendance_status] = "present" )

Absent = CALCULATE ( [Expected], fact_attendance[attendance_status] = "absent" )

Not Marked = CALCULATE ( [Expected], fact_attendance[attendance_status] = "not_marked" )

Attendance Rate = DIVIDE ( [Present], [Present] + [Absent] )

Last Present Date =
CALCULATE (
    MAX ( fact_attendance[event_date] ),
    fact_attendance[attendance_status] = "present"
)

Birthday This Month =
IF (
    SELECTEDVALUE ( dim_member[birth_month] ) = MONTH ( TODAY () )
        && [Expected] > 0,
    1,
    0
)
```

## Activity Counts

These count entities that appear in `fact_attendance`, so they respond to
every slicer — church, department, class, activity and year.

| Measure | Why | Used in |
|---|---|---|
| `Members` | Members with attendance in the current filters. | KPI cards (Overview, Church), Members by Department and Members by Age (Church) |
| `Families` | Families with at least one member attending. | KPI cards (Overview, Church) |
| `Classes` | Classes with attendance. | KPI cards (Overview, Church) |
| `Departments` | Departments with attendance. | KPI cards (Overview, Church) |
| `Activities` | Activity types held. | KPI cards (Overview, Church) |
| `Churches` | Churches in the current selection. | KPI card (Overview) |
| `Dioceses` | Dioceses in the current selection. | KPI card (Overview) |

```dax
Members = CALCULATE ( DISTINCTCOUNT ( dim_member[member_id] ), fact_attendance )

Families = CALCULATE ( DISTINCTCOUNT ( dim_member[family_id] ), fact_attendance )

Classes = CALCULATE ( DISTINCTCOUNT ( fact_attendance[class_id] ), fact_attendance )

Departments = CALCULATE ( COUNT ( dim_class[department_name] ), fact_attendance )

Activities = CALCULATE ( DISTINCTCOUNT ( dim_activity[activity_name] ), fact_attendance )

Churches = DISTINCTCOUNT ( dim_church[church_id] )

Dioceses = DISTINCTCOUNT ( dim_church[diocese_id] )
```

## Registered Counts

These count current enrolment regardless of attendance, so members who have
never attended are still included. `TREATAS` applies the church filter
directly to `dim_member[church_id]` instead of going through the fact table.

| Measure | Why | Used in |
|---|---|---|
| `Registered Members` | Current members of each church, attending or not — the size of the congregation rather than of the turnout. | Registered Members by church (Overview) |
| `Registered Families` | Current families of each church, attending or not. | Not shown on the current pages |

```dax
Registered Members =
CALCULATE (
    DISTINCTCOUNT ( dim_member[member_id] ),
    TREATAS ( VALUES ( dim_church[church_id] ), dim_member[church_id] ),
    dim_member[is_current_member] = TRUE ()
)

Registered Families =
CALCULATE (
    DISTINCTCOUNT ( dim_member[family_id] ),
    TREATAS ( VALUES ( dim_church[church_id] ), dim_member[church_id] ),
    dim_member[is_current_member] = TRUE ()
)
```
