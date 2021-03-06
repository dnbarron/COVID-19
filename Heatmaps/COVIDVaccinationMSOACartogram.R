rm(list=ls())

library(curl)
library(tidyverse)
library(readxl)
library(paletteer)
library(sf)
library(scales)
library(ragg)
library(gtools)
library(ggridges)
library(patchwork)
library(extrafont)

#Download vaccination data by MSOA
#https://www.england.nhs.uk/statistics/statistical-work-areas/covid-19-vaccinations/
vax <- tempfile()
url <- "https://www.england.nhs.uk/statistics/wp-content/uploads/sites/2/2021/03/COVID-19-weekly-announced-vaccinations-11-March-2021.xlsx"
vax <- curl_download(url=url, destfile=vax, quiet=FALSE, mode="wb")

vaxdata <- read_excel(vax, sheet="MSOA", range="F16:M6806", col_names=FALSE) %>% 
  rename(msoa11cd=`...1`, msoa11nm=`...2`, `<60`=`...3`, `60-64`=`...4`, `65-69`=`...5`, `70-74`=`...6`, 
         `75-79`=`...7`, `80+`=`...8`) %>% 
  gather(age, vaccinated, c(3:8))

#Download IMD data
temp <- tempfile()
source <- ("https://assets.publishing.service.gov.uk/government/uploads/system/uploads/attachment_data/file/833970/File_1_-_IMD2019_Index_of_Multiple_Deprivation.xlsx")
temp <- curl_download(url=source, destfile=temp, quiet=FALSE, mode="wb")

IMD <- read_excel(temp, sheet="IMD2019", range="A2:F32845", col_names=FALSE)[,c(1,2,5,6)]
colnames(IMD) <- c("LSOA11CD", "LSOA11NM", "IMDrank", "IMDdecile")

#Download LSOA to MSOA lookup
temp <- tempfile()
source <- ("https://opendata.arcgis.com/datasets/fe6c55f0924b4734adf1cf7104a0173e_0.csv")
temp <- curl_download(url=source, destfile=temp, quiet=FALSE, mode="wb")

lookup <- read.csv(temp) %>% 
  select(LSOA11CD, MSOA11CD, RGN11NM) %>% 
  unique()

#Merge into IMD data
IMD <- merge(IMD, lookup, by="LSOA11CD")

#Bring in population data for LSOAs
temp <- tempfile()
temp2 <- tempfile()
source <- "https://www.ons.gov.uk/file?uri=%2fpeoplepopulationandcommunity%2fpopulationandmigration%2fpopulationestimates%2fdatasets%2flowersuperoutputareamidyearpopulationestimatesnationalstatistics%2fmid2019sape22dt13/sape22dt13mid2019lsoabroadagesestimatesunformatted.zip"
temp <- curl_download(url=source, destfile=temp, quiet=FALSE, mode="wb")
unzip(zipfile=temp, exdir=temp2)

pop <- read_excel(file.path(temp2, "SAPE22DT13-mid-2019-lsoa-Broad_ages-estimates-unformatted.xlsx"),
                  sheet="Mid-2019 Persons", range="A6:G34758", col_names=FALSE)[,c(1,7)]
colnames(pop) <- c("LSOA11CD", "pop")

#Merge into IMD data
IMD <- merge(IMD, pop)

#Calculate IMD rank at MSOA level as weighted average of LSOA level ranks, weight by population
IMD_MSOA <- IMD %>% 
  group_by(MSOA11CD) %>% 
  summarise(IMDrank=weighted.mean(IMDrank, pop), pop=sum(pop)) %>% 
  ungroup() 

pop2 <- read_excel(vax, sheet="Population estimates (NIMS)", range="M16:U6806", col_names=FALSE) %>% 
  select(-c(2)) %>% 
  rename(msoa11cd=`...1`) %>% 
  gather(age, pop, c(2:8)) %>% 
  mutate(age=case_when(
    age %in% c("...3", "...4") ~ "<60",
    age=="...5" ~ "60-64",
    age=="...6" ~ "65-69",
    age=="...7" ~ "70-74",
    age=="...8" ~ "75-79",
    TRUE ~ "80+")) %>% 
  group_by(msoa11cd, age) %>% 
  summarise(pop=sum(pop)) %>% 
  ungroup()

#COMBINE
vaxdata <- merge(vaxdata, pop2) %>% 
  merge(IMD_MSOA %>% select(-pop), by.x="msoa11cd", by.y="MSOA11CD") %>% 
  mutate(vaxprop=vaccinated/pop)

#Add totals
vaxdata <- vaxdata %>% 
  group_by(msoa11cd, msoa11nm, IMDrank) %>% 
  summarise(vaccinated=sum(vaccinated), pop=sum(pop)) %>% 
  mutate(vaxprop=vaccinated/pop, age="Total") %>% 
  ungroup() %>% 
  bind_rows(vaxdata)

#Download Carl Baker's lovely cartogram
msoa <- tempfile()
source <- ("https://github.com/houseofcommonslibrary/uk-hex-cartograms-noncontiguous/raw/main/geopackages/MSOA.gpkg")
msoa <- curl_download(url=source, destfile=msoa, quiet=FALSE, mode="wb")

BackgroundMSOA <- st_read(msoa, layer="5 Background")

MSOA <- st_read(msoa, layer="4 MSOA hex") %>% 
  left_join(vaxdata, by="msoa11cd")

GroupsMSOA <- st_read(msoa, layer="2 Groups")

Group_labelsMSOA <- st_read(msoa, layer="1 Group labels") %>% 
  mutate(just=if_else(LabelPosit=="Left", 0, 1))

LAsMSOA <- st_read(msoa, layer="3 Local authority outlines (2019)")

plot <- ggplot()+
  geom_sf(data=BackgroundMSOA, aes(geometry=geom))+
  geom_sf(data=MSOA %>% filter(age=="80+"), 
          aes(geometry=geom, fill=vaxprop), colour=NA)+
  geom_sf(data=LAsMSOA %>% filter(RegionNation!="Wales"), 
          aes(geometry=geom), fill=NA, colour="White", size=0.1)+
  geom_sf(data=GroupsMSOA %>% filter(RegionNation!="Wales"), 
          aes(geometry=geom), fill=NA, colour="Black")+
  geom_sf_text(data=Group_labelsMSOA %>% filter(RegionNation!="Wales"), 
               aes(geometry=geom, label=Group.labe,
                                          hjust=just), size=rel(2.4), colour="Black")+
  scale_fill_paletteer_c("pals::ocean.haline", direction=-1, 
                         name="Proportion of\npopulation\nvaccinated", limits=c(0,1),
                         labels=label_percent(accuracy=1))+
  theme_void()+
  theme(plot.title=element_text(face="bold", size=rel(1.4)))+
  labs(title="Vaccination rates in the over 80s",
       subtitle="People vaccinated in England by Middle Super Output Area.",       
       caption="Data from NHS England and ONS, Cartogram from @carlbaker/House of Commons Library\nPlot by @VictimOfMaths")

agg_tiff("Outputs/COVIDVaxMSOA80+Cartogram.tiff", units="in", width=10, height=8, res=800)
plot
dev.off()

agg_png("Outputs/COVIDVaxMSOA80+Cartogram.png", units="in", width=10, height=8, res=800)
plot
dev.off()

plot2 <- ggplot()+
  geom_sf(data=BackgroundMSOA, aes(geometry=geom))+
  geom_sf(data=MSOA %>% filter(age=="75-79"), 
          aes(geometry=geom, fill=vaxprop), colour=NA)+
  geom_sf(data=LAsMSOA %>% filter(RegionNation!="Wales"), 
          aes(geometry=geom), fill=NA, colour="White", size=0.1)+
  geom_sf(data=GroupsMSOA %>% filter(RegionNation!="Wales"), 
          aes(geometry=geom), fill=NA, colour="Black")+
  geom_sf_text(data=Group_labelsMSOA %>% filter(RegionNation!="Wales"), 
               aes(geometry=geom, label=Group.labe,
                   hjust=just), size=rel(2.4), colour="Black")+
  scale_fill_paletteer_c("pals::ocean.haline", direction=-1, 
                         name="Proportion of\npopulation\nvaccinated", limits=c(0,1),
                         labels=label_percent(accuracy=1))+
  theme_void()+
  theme(plot.title=element_text(face="bold", size=rel(1.4)))+
  labs(title="Vaccination rates in 75-79 year olds",
       subtitle="People vaccinated in England by Middle Super Output Area.",       
       caption="Data from NHS England and ONS, Cartogram from @carlbaker/House of Commons Library\nPlot by @VictimOfMaths")

agg_tiff("Outputs/COVIDVaxMSOA75Cartogram.tiff", units="in", width=10, height=8, res=800)
plot2
dev.off()

agg_png("Outputs/COVIDVaxMSOA75Cartogram.png", units="in", width=10, height=8, res=800)
plot2
dev.off()

plot3 <- ggplot()+
  geom_sf(data=BackgroundMSOA, aes(geometry=geom))+
  geom_sf(data=MSOA %>% filter(age=="70-74"), 
          aes(geometry=geom, fill=vaxprop), colour=NA)+
  geom_sf(data=LAsMSOA %>% filter(RegionNation!="Wales"), 
          aes(geometry=geom), fill=NA, colour="White", size=0.1)+
  geom_sf(data=GroupsMSOA %>% filter(RegionNation!="Wales"), 
          aes(geometry=geom), fill=NA, colour="Black")+
  geom_sf_text(data=Group_labelsMSOA %>% filter(RegionNation!="Wales"), 
               aes(geometry=geom, label=Group.labe,
                   hjust=just), size=rel(2.4), colour="Black")+
  scale_fill_paletteer_c("pals::ocean.haline", direction=-1, 
                         name="Proportion of\npopulation\nvaccinated", limits=c(0,1),
                         labels=label_percent(accuracy=1))+
  theme_void()+
  theme(plot.title=element_text(face="bold", size=rel(1.4)))+
  labs(title="Vaccination rates in 70-74 year olds",
       subtitle="People vaccinated in England by Middle Super Output Area.",       
       caption="Data from NHS England and ONS, Cartogram from @carlbaker/House of Commons Library\nPlot by @VictimOfMaths")

agg_tiff("Outputs/COVIDVaxMSOA70Cartogram.tiff", units="in", width=10, height=8, res=800)
plot3
dev.off()

agg_png("Outputs/COVIDVaxMSOA70Cartogram.png", units="in", width=10, height=8, res=800)
plot3
dev.off()

plot4 <- ggplot()+
  geom_sf(data=BackgroundMSOA, aes(geometry=geom))+
  geom_sf(data=MSOA %>% filter(age=="65-69"), 
          aes(geometry=geom, fill=vaxprop), colour=NA)+
  geom_sf(data=LAsMSOA %>% filter(RegionNation!="Wales"), 
          aes(geometry=geom), fill=NA, colour="White", size=0.1)+
  geom_sf(data=GroupsMSOA %>% filter(RegionNation!="Wales"), 
          aes(geometry=geom), fill=NA, colour="Black")+
  geom_sf_text(data=Group_labelsMSOA %>% filter(RegionNation!="Wales"), 
               aes(geometry=geom, label=Group.labe,
                   hjust=just), size=rel(2.4), colour="Black")+
  scale_fill_paletteer_c("pals::ocean.haline", direction=-1, 
                         name="Proportion of\npopulation\nvaccinated", limits=c(0,1),
                         labels=label_percent(accuracy=1))+
  theme_void()+
  theme(plot.title=element_text(face="bold", size=rel(1.4)))+
  labs(title="Vaccination rates in 65-69 year olds",
       subtitle="People vaccinated in England by Middle Super Output Area.",       
       caption="Data from NHS England and ONS, Cartogram from @carlbaker/House of Commons Library\nPlot by @VictimOfMaths")

agg_tiff("Outputs/COVIDVaxMSOA65Cartogram.tiff", units="in", width=10, height=8, res=800)
plot4
dev.off()

agg_png("Outputs/COVIDVaxMSOA65Cartogram.png", units="in", width=10, height=8, res=800)
plot4
dev.off()

plot5 <- ggplot()+
  geom_sf(data=BackgroundMSOA, aes(geometry=geom))+
  geom_sf(data=MSOA %>% filter(age=="60-64"), 
          aes(geometry=geom, fill=vaxprop), colour=NA)+
  geom_sf(data=LAsMSOA %>% filter(RegionNation!="Wales"), 
          aes(geometry=geom), fill=NA, colour="White", size=0.1)+
  geom_sf(data=GroupsMSOA %>% filter(RegionNation!="Wales"), 
          aes(geometry=geom), fill=NA, colour="Black")+
  geom_sf_text(data=Group_labelsMSOA %>% filter(RegionNation!="Wales"), 
               aes(geometry=geom, label=Group.labe,
                   hjust=just), size=rel(2.4), colour="Black")+
  scale_fill_paletteer_c("pals::ocean.haline", direction=-1, 
                         name="Proportion of\npopulation\nvaccinated", limits=c(0,1),
                         labels=label_percent(accuracy=1))+
  theme_void()+
  theme(plot.title=element_text(face="bold", size=rel(1.4)))+
  labs(title="Vaccination rates in 60-64 year olds",
       subtitle="People vaccinated in England by Middle Super Output Area.",       
       caption="Data from NHS England and ONS, Cartogram from @carlbaker/House of Commons Library\nPlot by @VictimOfMaths")

agg_tiff("Outputs/COVIDVaxMSOA6064Cartogram.tiff", units="in", width=10, height=8, res=800)
plot5
dev.off()

agg_png("Outputs/COVIDVaxMSOA6064Cartogram.png", units="in", width=10, height=8, res=800)
plot5
dev.off()

plot6 <- ggplot()+
  geom_sf(data=BackgroundMSOA, aes(geometry=geom))+
  geom_sf(data=MSOA %>% filter(age=="<60"), 
          aes(geometry=geom, fill=vaxprop), colour=NA)+
  geom_sf(data=LAsMSOA %>% filter(RegionNation!="Wales"), 
          aes(geometry=geom), fill=NA, colour="White", size=0.1)+
  geom_sf(data=GroupsMSOA %>% filter(RegionNation!="Wales"), 
          aes(geometry=geom), fill=NA, colour="Black")+
  geom_sf_text(data=Group_labelsMSOA %>% filter(RegionNation!="Wales"), 
               aes(geometry=geom, label=Group.labe,
                   hjust=just), size=rel(2.4), colour="Black")+
  scale_fill_paletteer_c("pals::ocean.haline", direction=-1, 
                         name="Proportion of\npopulation\nvaccinated", limits=c(0,1),
                         labels=label_percent(accuracy=1))+
  theme_void()+
  theme(plot.title=element_text(face="bold", size=rel(1.4)))+
  labs(title="Vaccination rates in under 60s",
       subtitle="People vaccinated in England by Middle Super Output Area.",       
       caption="Data from NHS England and ONS, Cartogram from @carlbaker/House of Commons Library\nPlot by @VictimOfMaths")

agg_tiff("Outputs/COVIDVaxMSOAu60Cartogram.tiff", units="in", width=10, height=8, res=800)
plot6
dev.off()

agg_png("Outputs/COVIDVaxMSOAu60Cartogram.png", units="in", width=10, height=8, res=800)
plot6
dev.off()

plot7 <- ggplot()+
  geom_sf(data=BackgroundMSOA, aes(geometry=geom))+
  geom_sf(data=MSOA %>% filter(age=="Total"), 
          aes(geometry=geom, fill=vaxprop), colour=NA)+
  geom_sf(data=LAsMSOA %>% filter(RegionNation!="Wales"), 
          aes(geometry=geom), fill=NA, colour="White", size=0.1)+
  geom_sf(data=GroupsMSOA %>% filter(RegionNation!="Wales"), 
          aes(geometry=geom), fill=NA, colour="Black")+
  geom_sf_text(data=Group_labelsMSOA %>% filter(RegionNation!="Wales"), 
               aes(geometry=geom, label=Group.labe,
                   hjust=just), size=rel(2.4), colour="Black")+
  scale_fill_paletteer_c("pals::ocean.haline", direction=-1, 
                         name="Proportion of\npopulation\nvaccinated", limits=c(0,1),
                         labels=label_percent(accuracy=1))+
  theme_void()+
  theme(plot.title=element_text(face="bold", size=rel(1.4)))+
  labs(title="Overall adult vaccination rates",
       subtitle="People vaccinated in England by Middle Super Output Area.",       
       caption="Data from NHS England and ONS, Cartogram from @carlbaker/House of Commons Library\nPlot by @VictimOfMaths")

agg_tiff("Outputs/COVIDVaxMSOACartogram.tiff", units="in", width=10, height=8, res=800)
plot7
dev.off()

agg_png("Outputs/COVIDVaxMSOACartogram.png", units="in", width=10, height=8, res=800)
plot7
dev.off()

#Calculate deprivation gradients within IMD deciles
#Allocate to deciles
vaxdeciles <- vaxdata %>% 
  mutate(decile=quantcut(-IMDrank, 10, labels=FALSE)) %>% 
  group_by(age, decile) %>% 
  mutate(decilemean=sum(vaccinated)/sum(pop)) %>% 
  ungroup() %>% 
  group_by(age) %>% 
  mutate(popmean=sum(vaccinated)/sum(pop)) %>% 
  ungroup()

agg_tiff("Outputs/COVIDVaxMSOASxIMDScatter.tiff", units="in", width=12, height=8, res=800)
ggplot(vaxdeciles %>% filter(age=="80+"), 
       aes(x=vaxprop, y=as.factor(decile), colour=vaxprop))+
  geom_jitter(shape=21, alpha=0.6, show.legend=FALSE)+
  geom_segment(aes(x=popmean, xend=popmean, y=Inf, yend=-Inf), colour="Grey20")+
  geom_point(aes(x=decilemean, y=as.factor(decile)), colour="Grey20", fill="Cyan", shape=23, size=2)+
  scale_colour_paletteer_c("viridis::magma", direction=-1)+
  scale_x_continuous(name="Proportion of 80+ population vaccinated",
                     labels=label_percent(accuracy=1))+
  scale_y_discrete(name="Index of Multiple Deprivation", labels=c("1 - least deprived", "2", "3", "4", "5", "6", "7", 
                                                                    "8", "9", "10 - most deprived"))+  
  theme_classic()+
  theme(plot.title=element_text(face="bold", size=rel(1.4)))+
  labs(title="COVID vaccine uptake is lower in more deprived areas in England",
       subtitle="Number of people aged 80+ vaccinated by MSOA compared compared to the estimated 80+ population in 2019.",
       caption="Vaccination data from NHS England, Population data from ONS\nPlot by @VictimOfMaths")+
  annotate("text", x=0.3, y=9.9, label="Each circle = 1 MSOA", size=3)+
  annotate("text", x=0.8, y=6.5, label="Population average", size=3)+
  annotate("text", x=1.05, y=3.5, label="Decile average", size=3)+
  geom_segment(aes(x=0.88, y=6.5,  xend=0.942, yend=6.5), colour="Grey20")+
  geom_segment(aes(x=1.05, y=3.55,  xend=0.975, yend=3.95), colour="Grey20")
dev.off()

agg_tiff("Outputs/COVIDVaxMSOASxIMDRidges.tiff", units="in", width=8, height=6, res=800)
ggplot(vaxdeciles %>% filter(age=="Total"),
       aes(x=vaxprop, y=as.factor(decile), fill=vaxprop))+
  geom_density_ridges_gradient(aes(fill=stat(x)), rel_min_height=0.01, show.legend=FALSE)+
  scale_y_discrete(name="Index of Multiple Deprivation", labels=c("1 - least deprived", "2", "3", "4", "5", "6", "7", 
                                                                  "8", "9", "10 - most deprived"))+ 
  scale_x_continuous(name="Proportion of adult population vaccinated",
                     labels=label_percent(accuracy=1))+
  scale_fill_paletteer_c("pals::ocean.haline", direction=-1)+
  theme_classic()+
  theme(plot.title=element_text(face="bold", size=rel(1.4)))+
  labs(title="Vaccination rates in England are lower in more deprived areas",
       subtitle="Distribution of MSOA-level vaccination rates for adults (aged 16+) in England",
       caption="Data from NHS England | Plot by @VictimOfMaths")
dev.off()

agg_tiff("Outputs/COVIDVaxMSOASxIMDxAgeRidges.tiff", units="in", width=10, height=7, res=800)
ggplot(vaxdeciles %>% filter(age!="Total"),
       aes(x=vaxprop, y=as.factor(decile), fill=vaxprop))+
  geom_density_ridges_gradient(aes(fill=stat(x)), rel_min_height=0.01, show.legend=FALSE)+
  scale_y_discrete(name="Index of Multiple Deprivation", labels=c("1 - least deprived", "2", "3", "4", "5", "6", "7", 
                                                                  "8", "9", "10 - most deprived"))+ 
  scale_x_continuous(name="Proportion of population vaccinated",
                     labels=label_percent(accuracy=1))+
  scale_fill_paletteer_c("pals::ocean.haline", direction=-1)+
  facet_wrap(~age)+
  theme_classic()+
  theme(plot.title=element_text(face="bold", size=rel(1.4)),
        strip.background=element_blank(),
        strip.text=element_text(face="bold", size=rel(1)))+
  labs(title="Vaccination rates in England are lower in more deprived areas",
       subtitle="Distribution of MSOA-level vaccination rates for adults (aged 16+) in England",
       caption="Data from NHS England | Plot by @VictimOfMaths")
dev.off()

agg_tiff("Outputs/COVIDVaxMSOASxIMDScatterxAge.tiff", units="in", width=12, height=8, res=800)
ggplot(vaxdata %>% filter(age!="Total"), aes(x=vaxprop, y=-IMDrank, colour=vaxprop))+
  geom_point(shape=21, alpha=0.6, show.legend=FALSE)+
  scale_x_continuous(name="Proportion of population vaccinated", labels=label_percent(accuracy=1))+
  scale_y_continuous(name="Index of Multiple Deprivation", breaks=c(0, -32507),
                     labels=c("Most deprived", "Least deprived"))+
  scale_colour_paletteer_c("pals::ocean.haline", direction=-1)+
  facet_wrap(~age)+
  theme_classic()+
  theme(strip.background=element_blank(), strip.text=element_text(face="bold", size=rel(1)),
        plot.title=element_text(face="bold", size=rel(1.4)))+
  labs(title="COVID vaccine uptake is lower in more deprived areas in England",
       subtitle="Number of people vaccinated by age group and MSOA compared compared to the estimated population in 2019.",
       caption="Vaccination data from NHS England, Population data from ONS\nPlot by @VictimOfMaths")
dev.off()

agg_tiff("Outputs/COVIDVaxMSOASxIMDScatter.tiff", units="in", width=12, height=8, res=800)
ggplot(vaxdata %>% filter(age=="Total"), aes(x=vaxprop, y=-IMDrank, colour=vaxprop))+
  geom_point(shape=21, alpha=0.6, show.legend=FALSE)+
  scale_x_continuous(name="Proportion of population vaccinated", labels=label_percent(accuracy=1))+
  scale_y_continuous(name="Index of Multiple Deprivation", breaks=c(0, -32507),
                     labels=c("Most deprived", "Least deprived"))+
  scale_colour_paletteer_c("pals::ocean.haline", direction=-1)+
  theme_classic()+
  theme(strip.background=element_blank(), strip.text=element_text(face="bold", size=rel(1)),
        plot.title=element_text(face="bold", size=rel(1.4)))+
  labs(title="COVID vaccine uptake is lower in more deprived areas in England",
       subtitle="Number of people vaccinated by age group and MSOA compared compared to the estimated population in 2019.",
       caption="Vaccination data from NHS England, Population data from ONS\nPlot by @VictimOfMaths")
dev.off()

#############################
#Local analysis
#Download MSOA map
#Download shapefile of LA boundaries
temp <- tempfile()
temp2 <- tempfile()
source <- "https://opendata.arcgis.com/datasets/826dc85fb600440889480f4d9dbb1a24_0.zip?outSR=%7B%22latestWkid%22%3A27700%2C%22wkid%22%3A27700%7D"
temp <- curl_download(url=source, destfile=temp, quiet=FALSE, mode="wb")
unzip(zipfile=temp, exdir=temp2)

#The actual shapefile has a different name each time you download it, so need to fish the name out of the unzipped file
name <- list.files(temp2, pattern=".shp")
shapefile <- st_read(file.path(temp2, name))


map <- full_join(shapefile, MSOA %>% select(Laname, msoa11cd, IMDrank, vaxprop, pop, age) %>% as.data.frame(), 
                 by="msoa11cd", all.y=TRUE)

SheffIMD <- map %>% filter(age=="Total" & Laname=="Sheffield") %>% 
  ggplot()+
  geom_sf(aes(geometry=geometry, fill=IMDrank), show.legend=FALSE, colour=NA)+
  scale_fill_paletteer_c("pals::ocean.matter")+
  theme_void()+
  theme(plot.title=element_text(face="bold", size=rel(1.4)), text=element_text(family="Roboto"))+
  labs(title="Index of Multiple deprivation",
       subtitle="Darker colours = more deprived")

Sheffvax <- map %>% filter(age!="Total" & Laname=="Sheffield") %>% 
  ggplot()+
  geom_sf(aes(geometry=geometry, fill=vaxprop), colour=NA)+
  facet_wrap(~age)+
  scale_fill_paletteer_c("pals::ocean.haline", direction=-1, 
                         name="Proportion of\npopulation\nvaccinated", limits=c(0,1),
                         labels=label_percent(accuracy=1))+
  theme_void()+
  theme(plot.title=element_text(face="bold", size=rel(1.4)), text=element_text(family="Roboto"))+
  labs(title="COVID-19 vaccination rates",
       caption="Data from NHS England and ONS, Cartogram from @carlbaker/House of Commons Library\nPlot by @VictimOfMaths")

agg_tiff("Outputs/COVIDVaxMSOASSheffield.tiff", units="in", width=12, height=8, res=800)
SheffIMD+Sheffvax
dev.off()

